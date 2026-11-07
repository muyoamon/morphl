const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const st0 = stage0(b, target, optimize);
    const exe = st0.exe;
    const diag = st0.mods[0];
    const keyword = st0.mods[1];
    const lexer = st0.mods[2];
    const ast = st0.mods[3];
    const parser = st0.mods[4];
    const interp = st0.mods[5];
    const main_mod = st0.mods[6];

    // The interpreter every morphl test step runs on. A Debug build interprets about 9x
    // slower, and the slowest test (`tyio_test` over `emit.mpl`, since compiled) took 724s
    // Debug against 88s ReleaseSafe — which set `zig build test`'s wall time on its own.
    // ReleaseSafe keeps Zig's safety checks, so a bug in stage 0 still traps rather than
    // misbehaving. `-Doptimize=` above Debug is used as given; the installed `morphlc` and
    // the Zig unit tests are unaffected.
    const runner = if (optimize == .Debug) stage0(b, target, .ReleaseSafe).exe else exe;

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run morphlc").dependOn(&run.step);

    // `zig build test` runs every module's tests. Each module is also testable
    // directly, e.g. `zig test -Mroot=lib/lexer/lexer.zig ...` — but the
    // import wiring makes `zig build test` the path of least friction.
    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{ diag, keyword, lexer, ast, parser, interp, main_mod }) |mod| {
        const t = b.addTest(.{ .root_module = mod });
        const mod_run = b.addRunArtifact(t);
        // From the build root, so a test may read a source file by path — the
        // root-block agreement test reads `stage1/infer.mpl`.
        mod_run.setCwd(b.path("."));
        test_step.dependOn(&mod_run.step);
    }

    // STYLE.md's mechanical rules over stage 1's morphl source: no tabs, no trailing
    // whitespace, 100 columns with a string literal's contents exempt. Side effects,
    // because the `.mpl` files are not declared inputs and a cached pass would outlive
    // an edit — the same reason every stage-1 step has them.
    const style_exe = b.addExecutable(.{
        .name = "stylecheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/stylecheck.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const style_run = b.addRunArtifact(style_exe);
    style_run.setCwd(b.path("."));
    style_run.addArgs(&.{ "stage1", "stage1/fixtures", "std", "lsp" });
    style_run.has_side_effects = true;
    const style_step = b.step("test-style", "Check stage 1's morphl source against STYLE.md");
    style_step.dependOn(&style_run.step);
    test_step.dependOn(&style_run.step);

    // Stage 1's own tests, written in morphl and run by stage 0 (`runner`, ReleaseSafe
    // unless asked otherwise). They read their own source by path, so the run has to
    // happen from the build root.
    const stage1_step = b.step("test-stage1", "Run stage 1's morphl tests under stage 0");
    for ([_][]const u8{
        "stage1/lexer_test.mpl",
        "stage1/parser_test.mpl",
        "stage1/types_test.mpl",
        "stage1/infer_test.mpl",
        "stage1/ir_test.mpl",
        "stage1/lower_test.mpl",
        "stage1/emit_test.mpl",
        "stage1/compiler_test.mpl",
    }) |suite| {
        const suite_run = b.addRunArtifact(runner);
        suite_run.addArgs(&.{ "--run", suite });
        suite_run.setCwd(b.path("."));
        suite_run.expectExitCode(0);
        // The suite reads its `.mpl` sources at *run* time, so the build graph
        // does not know they are inputs and would serve a cached success after
        // stage 1 changed. These are tests; running them every time is right.
        suite_run.has_side_effects = true;
        stage1_step.dependOn(&suite_run.step);
        test_step.dependOn(&suite_run.step);
    }

    // The round trip stage 2 will need: morphl → C → binary → the right answer.
    // Compiled at -O0 on purpose, so that a tail call surviving as a call would
    // overflow rather than be optimised into a loop behind our backs — the loop
    // has to be ours (§6a).
    // ---------------------------------------------------------------- stage 2
    //
    // `bootstrap/mplc.c` is stage 1 emitted by stage 1 — BOOTSTRAP's stage 2 —
    // and it is committed on purpose. Regenerating it from stage 0 costs ~90
    // minutes; `cc` costs seconds. That is the usual bootstrap trade, and the
    // alternative is worse: the fast compiler would exist only on whichever
    // machine last built it, which is exactly where it was before this step.
    const stage2_step = b.step("stage2", "Build mplc from the committed bootstrap C");
    // `-Wno-unused-but-set-variable` for §7.8's `⊥`: a `panic`'s result gets a
    // temporary that is assigned and never read, because nothing after a `panic`
    // runs. Correct C for the construct, so it is silenced rather than worked
    // around — same judgement as `-Wno-unused-function` for the fixtures.
    const mplc_cc = b.addSystemCommand(&.{
        "cc", "-O2", "-Wall", "-Wno-unused-function", "-Wno-unused-but-set-variable", "-o",
    });
    const mplc_bin = mplc_cc.addOutputFileArg("mplc");
    mplc_cc.addFileArg(b.path("bootstrap/mplc.c"));
    stage2_step.dependOn(&b.addInstallBinFile(mplc_bin, "mplc").step);

    const s2_step = b.step("test-stage2", "mplc against stage 0, and the committed C against itself");

    const emit_step = b.step("test-emit", "Compile each fixture to C, build it, run it");
    const run0_step = b.step("test-run0", "Run each fixture under stage 0 and check it answers as compiled");
    // §7.6 makes a `$new` a C local, released by C's return, and §5.3a is the whole of
    // what makes that sound. A wrong lifetime is a dangling stack pointer, which an
    // ordinary run may well survive, so every fixture also runs under AddressSanitizer —
    // with use-after-return detection, which is what catches a local outliving its
    // function — and UBSan, and must print nothing but its answer.
    const asan_step = b.step("test-asan", "Run each fixture under AddressSanitizer and UBSan");
    // `host` is an extra C file linked in beside the emitted one: §4.16's fixture
    // needs C functions to bind, and providing them here is the point — a symbol
    // from libc proves nothing about a signature the target supplies itself.
    // `stage0 = false` marks a fixture outside stage 0's subset (BOOTSTRAP.md §1.2) other
    // than through `$extern`.
    for ([_]struct { src: []const u8, want: []const u8, host: ?[]const u8 = null, stage0: bool = true }{
        .{ .src = "stage1/fixtures/fact.mpl", .want = "3628800\n" },
        .{ .src = "stage1/fixtures/blocks.mpl", .want = "16\n" },
        .{ .src = "stage1/fixtures/strings.mpl", .want = "hello, world! 9 a\n" },
        .{ .src = "stage1/fixtures/storage.mpl", .want = "154\n" },
        .{ .src = "stage1/fixtures/match.mpl", .want = "25\n" },
        // §4.7's catch-all on a name bound to storage, which stage 0 alone never matched:
        // it dereferenced the scrutinee and not a name pattern. 2122121.
        .{ .src = "stage1/fixtures/match_storage.mpl", .want = "2122121\n" },
        .{ .src = "stage1/fixtures/closures.mpl", .want = "42\n" },
        .{ .src = "stage1/fixtures/try.mpl", .want = "5\n" },
        .{ .src = "stage1/fixtures/local_try.mpl", .want = "563786\n" },
        .{ .src = "stage1/fixtures/mutual.mpl", .want = "1\n" },
        .{ .src = "stage1/fixtures/mutual_sig.mpl", .want = "9\n" },
        .{ .src = "stage1/fixtures/unions.mpl", .want = "91\n" },
        .{ .src = "stage1/fixtures/props.mpl", .want = "169\n" },
        .{ .src = "stage1/fixtures/template.mpl", .want = "43\n" },
        .{ .src = "stage1/fixtures/import.mpl", .want = "57\n" },
        .{ .src = "stage1/fixtures/list.mpl", .want = "20\n" },
        .{ .src = "stage1/fixtures/group.mpl", .want = "49\n" },
        .{ .src = "stage1/fixtures/coerce.mpl", .want = "321\n" },
        .{ .src = "stage1/fixtures/scope.mpl", .want = "17\n" },
        .{ .src = "stage1/fixtures/alloc.mpl", .want = "41\n" },
        .{ .src = "stage1/fixtures/option.mpl", .want = "33\n" },
        .{ .src = "stage1/fixtures/mutual_import.mpl", .want = "5\n" },
        .{ .src = "stage1/fixtures/mu_group.mpl", .want = "2143\n" },
        .{ .src = "stage1/fixtures/ref_join.mpl", .want = "387101242\n" },
        .{ .src = "stage1/fixtures/match_scrut.mpl", .want = "6\n" },
        // An intrinsic's option whose payload nothing reads: its members were never
        // interned, and the union came out as two `int64_t`s that `cc` refused.
        .{ .src = "stage1/fixtures/opt_unread.mpl", .want = "86322\n" },
        // A value template as an inline constructor: its `$new`'s deferral belongs to the
        // `$decl` that binds the instance, as a `$new` written there would.
        .{ .src = "stage1/fixtures/tmpl_own.mpl", .want = "213654987321112 hits=1" },
        // A `$new` with a deferral in a parameter default, a type-only position: its
        // deferral was left on the enclosing frame and named captures it did not have.
        .{ .src = "stage1/fixtures/default_defer.mpl", .want = "421\n" },
        .{ .src = "stage1/fixtures/effect_drop.mpl", .want = "7041\n" },
        .{ .src = "stage1/fixtures/prop_union.mpl", .want = "9\n" },
        // §3.3's top-level `$prop`s. All four shapes §1.1 allows, because each takes a
        // different route through `lower_prop_*`: a scalar is read off the type, a
        // prop-only block and a `$func` keep their source, and a `$template` is what
        // `$specialize` consumes. 58, and before the fix this did not lower at all.
        .{ .src = "stage1/fixtures/topprop.mpl", .want = "58\n" },
        // An **empty** module is a valid empty block (§3.3, §2.1), not an error. Both
        // passes flattened §8's `read_file` option to a string, so a file that could not
        // be read and a file that is empty were one case. 9.
        .{ .src = "stage1/fixtures/empty_import.mpl", .want = "9\n" },
        .{ .src = "stage1/fixtures/effect.mpl", .want = "46\n" },
        .{ .src = "stage1/fixtures/init_order.mpl", .want = "106\n" },
        .{ .src = "stage1/fixtures/alias.mpl", .want = "42\n" },
        .{ .src = "stage1/fixtures/tramp.mpl", .want = "21\n" },
        .{ .src = "stage1/fixtures/tramp_shim.mpl", .want = "7864\n" },
        .{ .src = "stage1/fixtures/tramp_up.mpl", .want = "536922\n" },
        .{ .src = "stage1/fixtures/extern.mpl", .want = "185\n",
           .host = "stage1/fixtures/extern_host.c" },
        .{ .src = "stage1/fixtures/arrays.mpl", .want = "12\n" },
        // §8's arrays at any element type — `Int`, a record, `Bool`, an array — each call
        // typed from its own arguments (STDLIB.md, P3). 5012.
        .{ .src = "stage1/fixtures/arrays_any.mpl", .want = "5012\n" },
        .{ .src = "stage1/fixtures/write.mpl", .want = "161\n" },
        .{ .src = "stage1/fixtures/fwd_init.mpl", .want = "126\n" },
        .{ .src = "stage1/fixtures/fwd_local.mpl", .want = "1048\n" },
        .{ .src = "stage1/fixtures/module_value.mpl", .want = "41\n" },
        .{ .src = "stage1/fixtures/prop_param.mpl", .want = "98\n" },
        .{ .src = "stage1/fixtures/defaults.mpl", .want = "247\n" },
        .{ .src = "stage1/fixtures/init_fwd.mpl", .want = "22\n" },
        // §4.9's instance semantics for a template body with `$decl`s: storage per
        // evaluation, an argument evaluated once, props shared. 140.
        .{ .src = "stage1/fixtures/instance.mpl", .want = "140\n" },
        // The generic in type-only positions inside the `$decl`s, through the real
        // prelude's `list`. 6.
        .{ .src = "stage1/fixtures/instance_list.mpl", .want = "6\n" },
        // §4.9's self-specialisation, in the entry file and in a module member, and a
        // prop whose value is its own specialisation. 21.
        .{ .src = "stage1/fixtures/selfspec.mpl", .want = "21\n" },
        .{ .src = "stage1/fixtures/local_tmpl.mpl", .want = "573578\n" },
        .{ .src = "stage1/fixtures/local_prop.mpl", .want = "217646\n" },
        .{ .src = "stage1/fixtures/short_self.mpl", .want = "43607\n" },
        .{ .src = "stage1/fixtures/prim_value.mpl", .want = "32555871\n" },
        .{ .src = "stage1/fixtures/prop_dflt_local.mpl", .want = "34685\n" },
        .{ .src = "stage1/fixtures/short_alias.mpl", .want = "436\n" },
        .{ .src = "stage1/fixtures/prim_alias.mpl", .want = "44000000\n" },
        .{ .src = "stage1/fixtures/tmpl_frame_fn.mpl", .want = "3442440001222220\n", .stage0 = false },
        .{ .src = "stage1/fixtures/tmpl_value.mpl", .want = "43532\n" },
        .{ .src = "stage1/fixtures/self_shadow.mpl", .want = "32426\n" },
        .{ .src = "stage1/fixtures/main_union.mpl", .want = "5\n" },
        .{ .src = "stage1/fixtures/bool_lit.mpl", .want = "1\n" },
        .{ .src = "stage1/fixtures/spec_self.mpl", .want = "684173\n" },
        .{ .src = "stage1/fixtures/spec_direct.mpl", .want = "351742\n" },
        .{ .src = "stage1/fixtures/spec_tmpl_gen.mpl", .want = "56873\n" },
        .{ .src = "stage1/fixtures/spec_gen_prop.mpl", .want = "12782\n" },
        .{ .src = "stage1/fixtures/spec_frame.mpl", .want = "1169533939\n" },
        .{ .src = "stage1/fixtures/frames.mpl", .want = "1111111111\n" },
        .{ .src = "stage1/fixtures/short_local.mpl", .want = "1111111\n" },
        .{ .src = "stage1/fixtures/shadow_root.mpl", .want = "83291\n" },
        .{ .src = "stage1/fixtures/field_depth.mpl", .want = "916\n" },
        // §4.9's compile-time generics: a value in the type, and tags made by a
        // template. 61.
        .{ .src = "stage1/fixtures/ctgen.mpl", .want = "61\n" },
        // §4.10's receiver: top level, a member taken as a value, a block local to a
        // function, `$mut` storage, and a copy. 48.
        .{ .src = "stage1/fixtures/receiver.mpl", .want = "48\n" },
        // §4.10: a member's parameter default naming its own block is the block's type, not
        // the receiver, directly, through a specialisation and on `$mut` storage. 4111.
        .{ .src = "stage1/fixtures/self_param.mpl", .want = "4111\n" },
        // P11: a non-generic function taking a block whose members read their receiver,
        // reached through the parameter's type before the block is built — in the entry
        // file, a module member and a `$fwd`'d function. 3294.
        .{ .src = "stage1/fixtures/recv_param.mpl", .want = "3294\n" },
        .{ .src = "stage1/fixtures/recv_fwd.mpl", .want = "6\n" },
        // A block built inside its own recursive constructor, with a member taking another
        // of its type: the constructor's result closes twice, and `unroll`'s memo must not
        // keep a mid-knot unrolling. At the top level and in a template. 6205.
        .{ .src = "stage1/fixtures/wrap_self.mpl", .want = "6205\n" },
        // §4.15a's `$defer`: a scope, a plain value, `$try` returning and not, and nested
        // scopes — each step a digit, so the answer is the order. 132456876798.
        .{ .src = "stage1/fixtures/defer.mpl", .want = "132456876798\n" },
        // A `$try` returning a member nothing else interns: emit missed it and injected
        // type 0, returning an uninitialised result. 3.
        .{ .src = "stage1/fixtures/try_member.mpl", .want = "3\n" },
        // DEFER.md step 3: `$decl x $new { … $defer … }` in a scope runs the storage's
        // deferrals at its owner's block's end, in order, and on a `$try`. 2136549.
        .{ .src = "stage1/fixtures/defer_new.mpl", .want = "2136549\n" },
        // DEFER.md step 3: ephemeral storage dies with its item, a record owns its fields'
        // storage, a value block passes it out, a `$try` runs what is alive. 345687132456.
        .{ .src = "stage1/fixtures/defer_own.mpl", .want = "345687132456\n" },
        // DEFER.md example 10: a `$new` block in an `$if` or `$match` arm runs its
        // deferrals only if the arm ran — a flag per site, and a `$try` in the other arm
        // runs nothing of it. 9192384875761.
        .{ .src = "stage1/fixtures/defer_arm.mpl", .want = "9192384875761\n" },
        // DEFER.md example 7: storage passed to a call that may hand it back is owned only
        // if the result reaches it, decided at run time in both stages. 21345768321945.
        .{ .src = "stage1/fixtures/defer_call.mpl", .want = "21345768321945\n" },
        // DEFER.md example 12: a file's top level is the program's scope, so its deferrals
        // run after `main`'s answer is printed, newest first — the entry's, then its module's.
        .{ .src = "stage1/fixtures/top_defer.mpl", .want = "tmp init main 18\nc b a e1 u2 u1\n" },
        // §4.14: a module initialises at its first `$import`, in source order, not before
        // its importer's first item; a nested `$import` likewise, and a second one not at all.
        .{ .src = "stage1/fixtures/import_order.mpl", .want = "e1 m1 i m2 e2 5\nde2 dm di de1 " },
        .{ .src = "stage1/fixtures/import_spell.mpl", .want = "i 5\n" },
        // A deferred prop read is a thunk lifted into the entry file's output, assigned
        // first; read as a value it used to be a zero pair and a crash. 2.
        .{ .src = "stage1/fixtures/init_lifted.mpl", .want = "2\n" },
        // §5.4 through a union of references, and a union of values whose shared prefix is
        // not the C union's: a switch on the discriminator, each member read where it has
        // the field. 134567892312.
        .{ .src = "stage1/fixtures/proj_ref.mpl", .want = "134567892312\n" },
        // §3.3: a block's trailing effects run after its slots. 123.
        .{ .src = "stage1/fixtures/trail.mpl", .want = "123\n" },
        // DEFER.md: a root resource made by `open`, with a deferral the root's `defer_at`
        // holds, freed by `close` — a function freeing its parameter — and through a
        // wrapper. 2431. Compiled only: stage 0 has no allocators.
        .{ .src = "stage1/fixtures/open_close.mpl", .want = "2431\n", .stage0 = false },
        // §4.7: a pattern is any expression — a projection onto a module's member, in a
        // `$match` and a `$try`, which lowering typed ⊥. 321. Stage 0 keeps patterns to
        // BOOTSTRAP §1.3's syntactic three.
        .{ .src = "stage1/fixtures/pattern_proj.mpl", .want = "321\n", .stage0 = false },
        // §2.3's tops as §4.7 patterns: `$case ()` covers anything, `$case {}` every block
        // member, a parameter defaulted to `()` takes any argument, and `$if c 5 ()` keeps
        // its `Int`. 654321.
        .{ .src = "stage1/fixtures/top.mpl", .want = "654321\n" },
        // §5.1's group rule: a prefix, depth inside it, a group as its first element, a
        // join of two lengths, a group answered at a shorter type. 35729. Compiled only:
        // stage 0 coerces nothing, so a group passed as its first element stays a group.
        .{ .src = "stage1/fixtures/group_prefix.mpl", .want = "35729\n", .stage0 = false },
        // §2.1's float literals with an exponent, through arithmetic. 163. Compiled only:
        // stage 0 has no float arithmetic.
        .{ .src = "stage1/fixtures/float_exp.mpl", .want = "163\n", .stage0 = false },
        // §3.6: a value enters a union as its most specific member, whatever the union's
        // order; first fit by position put it in the shorter one. 121 (221 before).
        .{ .src = "stage1/fixtures/inject.mpl", .want = "121\n" },
        // §7.4 on a function value: a coercion whose C signatures differ goes through a
        // shim, for a `()` or prefix result, a union member, a parameter the other way, a
        // callback's callback, a join, a cell and a tail call. The old backend crashed.
        .{ .src = "stage1/fixtures/fn_coerce.mpl", .want = "1243586789\n" },
        // The same through a trait object: a member answering a subtype of the trait's, or
        // taking a supertype, gets an adapter as its table entry. The old backend crashed.
        .{ .src = "stage1/fixtures/trait_coerce.mpl", .want = "7345869\n" },
        // One trait object used as another whose table is laid out differently: the target's
        // table is built from the source's, by member name. 2334 (4444 before).
        .{ .src = "stage1/fixtures/trait_retable.mpl", .want = "2334\n" },
        // ...and one whose member has another signature: the object is wrapped, its table
        // thunks over the original's entries. 534168 (refused before).
        .{ .src = "stage1/fixtures/trait_wrap.mpl", .want = "534168\n" },
        // The same with the resource in a library: `M.close` frees its parameter and
        // `M.open`'s result is root storage, facts inference hands lowering for a module
        // member (`member_facts`). 52431.
        .{ .src = "stage1/fixtures/open_mod.mpl", .want = "52431\n", .stage0 = false },
        // §4.9's application, and the `$specialize` of a `$func` body: inferred from an
        // argument, from a function argument's parameter and result, from a module's
        // template, and a template applying itself in tail position. Stage 0 refuses
        // application (BOOTSTRAP.md §1.1). 2000251.
        .{ .src = "stage1/fixtures/apply.mpl", .want = "2000251\n", .stage0 = false },
        // An `$overload` of templates (STDLIB.md, P7): `$specialize` by bounds — `Int`, a
        // trait, unbounded, nested with two generics — and `$call` by application, after a
        // function candidate and past one it cannot infer, per instance inside a template
        // body and across a module. Stage 0 has no types to check a bound against.
        // 12341381821107105.
        .{ .src = "stage1/fixtures/overload_tmpl.mpl", .want = "12341381821107105\n", .stage0 = false },
        // ...and a choice inside an instance whose argument inference closes into a `μ` only
        // through a prop's type, which lowering keyed differently until `T.show_key`. 210.
        .{ .src = "stage1/fixtures/overload_tmpl_mu.mpl", .want = "210\n", .stage0 = false },
        // §4.12's `$impl` over a union: methods on a result type that `$match` and `$try` see as
        // the union (STDLIB.md P15).
        .{ .src = "stage1/fixtures/with_union.mpl", .want = "91147\n" },
        // §4.12a's `$override`, on a value and on a template (STDLIB.md, P8). Stage 0 leaves
        // it out of the bootstrap subset.
        .{ .src = "stage1/fixtures/override.mpl", .want = "4 33 30 4 4 2 7 1400 1010 101 101\n", .stage0 = false },
        // §4.12a twice: an `$override` of a template an `$override` made, each override's
        // names resolving where it is written. 31410. Compiled only, as `override.mpl` is.
        .{ .src = "stage1/fixtures/override2.mpl", .want = "31410\n", .stage0 = false },
        // §6's trait objects: coercion at a call and at `$set`, `$traitsof` of a name, of
        // `$mut` storage and of an expression, `$impl` over an `Int`, and `$match` on an
        // object. 87.
        .{ .src = "stage1/fixtures/traits.mpl", .want = "87\n" },
        // ...and across a module boundary, the table in the shared header. 49.
        .{ .src = "stage1/fixtures/traits_split.mpl", .want = "49\n" },
        // §6: a scalar trait member (§9's `$prop name ""`), read through the object. 47.
        .{ .src = "stage1/fixtures/tscalar.mpl", .want = "47\n" },
        // §4.10: a read-only receiver is the target's storage, not a copy, so an object
        // made over it in a member outlives the call — through a shim and by projection. 33.
        .{ .src = "stage1/fixtures/recv_ref.mpl", .want = "33\n" },
        // TRAITS.md: a trait is its props as written — a member taking its block's own type
        // is callable through an object, and "any implementation" is `$traitsof`. 221.
        .{ .src = "stage1/fixtures/trait_written.mpl", .want = "221\n" },
        // TRAITS.md, design point 7: a trait naming itself, by its block's name and through
        // a specialisation of its template, tied by §5.5. 116.
        .{ .src = "stage1/fixtures/self_trait.mpl", .want = "116\n" },
        .{ .src = "stage1/fixtures/self_trait_adapt.mpl", .want = "501\n" },
        // §4.9's bounds in TRAITS.md's syntax — an F-bound, a trait bound, and a plain generic
        // beside a bounded one — checked at specialisation. 55.
        .{ .src = "stage1/fixtures/bounds.mpl", .want = "55\n" },
        // P10: a `$func` a block binds may name itself — a loop, a doubly recursive call,
        // and a helper allocating from a local arena it captures. 2000736.
        .{ .src = "stage1/fixtures/local_rec.mpl", .want = "2000736\n", .stage0 = false },
        .{ .src = "stage1/fixtures/local_rec0.mpl", .want = "2000610\n" },
        // §4.8's `$overload`: first fit, a nested overload, an overload argument, and
        // `x.i`. 362.
        .{ .src = "stage1/fixtures/overload.mpl", .want = "362\n" },
        // §3.1's `Float` with §8's overloads on it: printed through `to_str`, which
        // round-trips, and an exact `mod`. Stage 0 leaves `Float` out (BOOTSTRAP §1.2).
        .{ .src = "stage1/fixtures/float.mpl", .stage0 = false,
           .want = "0.30000000000000004 0.25 -1.5 2.0 7.0 6.0 0.75 9.999999999999999e+29 1.0 inf nan 126\n" },
        // §8's wrapping, saturating and bitwise intrinsics at the edges of the range, each
        // also passed as a value. Stage 0 used to remember the builtin a parameter held at
        // its first call, which this is the first fixture to notice.
        // BOOTSTRAP §2's `run`: exit status, signal and `none`, compared with stage 0.
        .{ .src = "stage1/fixtures/run.mpl", .want = "37710\n" },
        // §5.3a's borrowing (STORAGE.md §R): places handed back from a parameter, a
        // capture and the top level, and tail calls passing a borrowed place. 501542.
        .{ .src = "stage1/fixtures/borrow.mpl", .want = "501592\n" },
        // §7.6's frame storage as C locals: a 2,000,000-iteration loop reusing one, a cell
        // made in an `$if` arm and used after it, a group's, and top-level static storage.
        .{ .src = "stage1/fixtures/frame.mpl", .want = "2000001002635\n" },
        // §7.6's allocators: a morphl arena `$alloc` draws from by lexical scope, reset
        // and reused; and A4's advised rewrite, freeing through the root allocator. Both
        // reach §8's raw memory, which stage 0 leaves out of the subset.
        .{ .src = "stage1/fixtures/arena.mpl", .want = "50511058200320\n", .stage0 = false },
        .{ .src = "stage1/fixtures/alloc_free.mpl", .want = "1\n", .stage0 = false },
        // §4.16 with a C prototype in the symbol: libc bound directly, an `int` result
        // sign-extended, a pointer result as an address, and one used as a value.
        .{ .src = "stage1/fixtures/libc.mpl", .want = "hello\n205132\n", .stage0 = false },
        // §8's FFI addresses against a C host: bytes, elements, storage C writes
        // through, and memory C owns read and written through `unbox`.
        .{ .src = "stage1/fixtures/ffi.mpl", .want = "11117493\n",
           .host = "stage1/fixtures/ffi_host.c" },
        .{ .src = "stage1/fixtures/bits.mpl", .want = "-9223372036854775808 9223372036854775807 9223372036854775805 9223372036854775807 -9223372036854775808 -9223372036854775808 9223372036854775807 42 8 14 6 -9223372036854775808 -9223372036854775808 -4611686018427387904 -4 -1 1 -9223372036854775807 9223372036854775807 6 10 68\n" },
    }) |fixture| {
        // Every fixture twice: once straight, once with §9.2's pass in the
        // middle. The answer has to be the same both ways — that is the whole
        // claim, from either side. "The compiler never assumes a pass ran", so
        // `emit_c` must be right on unoptimised input; a pass may not change
        // what the program means, so `opt_c` must agree with it.
        for ([_][]const u8{ "stage1/emit_c.mpl", "stage1/opt_c.mpl" }) |driver| {
            const emit_run = b.addRunArtifact(runner);
            emit_run.addArgs(&.{ "--run", driver, fixture.src });
            emit_run.setCwd(b.path("."));
            // Same reason as above: the compiler is stage-1 source read at run
            // time, so a cached run would compile the previous compiler.
            emit_run.has_side_effects = true;
            const c_file = emit_run.captureStdOut(.{ .basename = "out.c" });

            // A compiler legitimately emits a static function nothing calls;
            // the rest of -Werror is worth keeping.
            const cc = b.addSystemCommand(&.{ "cc", "-O0", "-Wall", "-Wno-unused-function", "-Werror", "-o" });
            const bin = cc.addOutputFileArg("fixture");
            cc.addFileArg(c_file);
            if (fixture.host) |h| cc.addFileArg(b.path(h));

            const run_bin = std.Build.Step.Run.create(b, "run the emitted binary");
            run_bin.addFileArg(bin);
            run_bin.expectStdOutEqual(fixture.want);
            emit_step.dependOn(&run_bin.step);
            test_step.dependOn(&run_bin.step);

            if (std.mem.eql(u8, driver, "stage1/emit_c.mpl")) {
                // The strongest check in the project, and cheap enough to make routine
                // over every fixture: two executions of the same stage-1 source — this
                // one interpreted by stage 0, and `mplc`, compiled from the committed C —
                // must agree on every byte. A difference is the committed backend lagging
                // `stage1/` (regenerate it) or an interpreter and its compiled form
                // disagreeing on one program, which is a bug in one of them. A fixture
                // emits no diagnostics (`emit_c.mpl` would print them ahead of the C),
                // which is also what lets `cc` compile `c_file` above. (`test-stage2`)
                const by_mplc = std.Build.Step.Run.create(b, "mplc emits the fixture");
                by_mplc.addFileArg(mplc_bin);
                by_mplc.addArg(fixture.src);
                by_mplc.setCwd(b.path("."));
                by_mplc.has_side_effects = true;
                const agree = b.addSystemCommand(&.{"cmp"});
                agree.addFileArg(by_mplc.captureStdOut(.{ .basename = "by_mplc.c" }));
                agree.addFileArg(c_file);
                s2_step.dependOn(&agree.step);
                test_step.dependOn(&agree.step);

                const acc = b.addSystemCommand(&.{
                    "cc", "-O0", "-g", "-Wall", "-Wno-unused-function", "-Werror",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-o",
                });
                const abin = acc.addOutputFileArg("fixture_asan");
                acc.addFileArg(c_file);
                if (fixture.host) |h| acc.addFileArg(b.path(h));
                const arun = std.Build.Step.Run.create(b, "run the emitted binary under ASan");
                arun.addFileArg(abin);
                // Leaks are expected: `$alloc` is never released until §7.6's allocators.
                arun.setEnvironmentVariable("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1");
                arun.setEnvironmentVariable("UBSAN_OPTIONS", "halt_on_error=1:print_stacktrace=1");
                arun.expectStdOutEqual(fixture.want);
                arun.expectStdErrEqual("");
                asan_step.dependOn(&arun.step);
                test_step.dependOn(&arun.step);

                // §7.6's point, measured: `frame.mpl`'s 2,000,000 cells fit in one local and
                // `alloc_free.mpl`'s million are each released, so both run in a cap that
                // the cells they make, unreleased, could not meet.
                if (std.mem.eql(u8, fixture.src, "stage1/fixtures/frame.mpl") or
                    std.mem.eql(u8, fixture.src, "stage1/fixtures/alloc_free.mpl"))
                {
                    const capped = b.addSystemCommand(&.{ "sh", "-c", "ulimit -v 20000; exec \"$0\"" });
                    capped.addFileArg(bin);
                    capped.expectStdOutEqual(fixture.want);
                    emit_step.dependOn(&capped.step);
                    test_step.dependOn(&capped.step);
                }
            }
        }

        // ...and once more under stage 0, which must give the same answer. The two are
        // independent implementations of one language, so agreeing on what a program
        // *means* is the strongest check either has; `--main` makes stage 0 call the
        // file's `main` and print it as the emitted `main` does. A fixture with a C host
        // needs `$extern`, which stage 0 leaves out of the subset (BOOTSTRAP.md §1.2).
        if (fixture.host == null and fixture.stage0) {
            const run0 = b.addRunArtifact(runner);
            run0.addArgs(&.{ "--run", "--main", fixture.src });
            run0.setCwd(b.path("."));
            run0.has_side_effects = true;
            run0.expectStdOutEqual(fixture.want);
            run0_step.dependOn(&run0.step);
            test_step.dependOn(&run0.step);
        }
    }
    // ------------------------------------------------- programs that must panic
    //
    // §3.1 makes `Int` overflow panic and §8 makes division by zero panic, so the
    // compiled program must abort with stage 0's message — and stage 0 must refuse
    // with the same one. Every other fixture checks an answer, which a program that
    // aborts cannot give, and the compiled C used to wrap silently instead.
    // `overflow.mpl` takes the case as its argument, so it is compiled once.
    const panic_step = b.step("test-panic", "Check Int overflow and division by zero panic in both stages");
    {
        const src = "stage1/fixtures/overflow.mpl";
        const emit_run = b.addRunArtifact(runner);
        emit_run.addArgs(&.{ "--run", "stage1/emit_c.mpl", src });
        emit_run.setCwd(b.path("."));
        emit_run.has_side_effects = true;
        const c_file = emit_run.captureStdOut(.{ .basename = "out.c" });
        const cc = b.addSystemCommand(&.{ "cc", "-O0", "-Wall", "-Wno-unused-function", "-Werror", "-o" });
        const bin = cc.addOutputFileArg("overflow");
        cc.addFileArg(c_file);
        for ([_]struct { case: []const u8, msg: []const u8 }{
            .{ .case = "add", .msg = "panic: Int overflow in add" },
            .{ .case = "sub", .msg = "panic: Int overflow in sub" },
            .{ .case = "mul", .msg = "panic: Int overflow in mul" },
            .{ .case = "div0", .msg = "panic: division by zero" },
            .{ .case = "divm", .msg = "panic: Int overflow in div" },
            .{ .case = "mod0", .msg = "panic: division by zero in mod" },
            .{ .case = "neg", .msg = "panic: Int overflow in neg" },
            .{ .case = "alias", .msg = "panic: Int overflow in sub" },
            .{ .case = "value", .msg = "panic: Int overflow in add" },
            .{ .case = "shl", .msg = "panic: shift count 64 out of range in shl" },
            .{ .case = "shr", .msg = "panic: shift count -1 out of range in shr" },
        }) |c| {
            const run_bin = std.Build.Step.Run.create(b, "run the overflow fixture");
            run_bin.addFileArg(bin);
            run_bin.addArg(c.case);
            run_bin.has_side_effects = true;
            run_bin.addCheck(.{ .expect_stderr_match = c.msg });
            run_bin.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            panic_step.dependOn(&run_bin.step);
            test_step.dependOn(&run_bin.step);

            const run0 = b.addRunArtifact(runner);
            run0.addArgs(&.{ "--run", "--main", src, c.case });
            run0.setCwd(b.path("."));
            run0.has_side_effects = true;
            run0.addCheck(.{ .expect_stderr_match = c.msg });
            run0.expectExitCode(1);
            panic_step.dependOn(&run0.step);
            test_step.dependOn(&run0.step);
        }
        // What was printed before a `panic` survives it (§7.8): stdout here is a pipe,
        // which C buffers and `abort` drops, so the runtime flushes first.
        {
            const psrc = "stage1/fixtures/panic_out.mpl";
            const pemit = b.addRunArtifact(runner);
            pemit.addArgs(&.{ "--run", "stage1/emit_c.mpl", psrc });
            pemit.setCwd(b.path("."));
            pemit.has_side_effects = true;
            const pc = pemit.captureStdOut(.{ .basename = "out.c" });
            const pcc = b.addSystemCommand(&.{ "cc", "-O0", "-Wall", "-Wno-unused-function", "-Wno-unused-but-set-variable", "-Werror", "-o" });
            const pbin = pcc.addOutputFileArg("panic_out");
            pcc.addFileArg(pc);
            const prun = std.Build.Step.Run.create(b, "run panic_out");
            prun.addFileArg(pbin);
            prun.has_side_effects = true;
            prun.addCheck(.{ .expect_stdout_exact = "before\n" });
            prun.addCheck(.{ .expect_stderr_match = "boom" });
            prun.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
            panic_step.dependOn(&prun.step);
            test_step.dependOn(&prun.step);
            const prun0 = b.addRunArtifact(runner);
            prun0.addArgs(&.{ "--run", "--main", psrc });
            prun0.setCwd(b.path("."));
            prun0.has_side_effects = true;
            prun0.addCheck(.{ .expect_stdout_exact = "before\n" });
            prun0.addCheck(.{ .expect_stderr_match = "boom" });
            prun0.expectExitCode(1);
            panic_step.dependOn(&prun0.step);
            test_step.dependOn(&prun0.step);
        }
        // ...and `mod` by -1 at the bottom of the range is 0, not C's undefined `%`.
        const ok = std.Build.Step.Run.create(b, "run the overflow fixture");
        ok.addFileArg(bin);
        ok.addArg("ok");
        ok.has_side_effects = true;
        ok.expectStdOutEqual("0\n");
        panic_step.dependOn(&ok.step);
        test_step.dependOn(&ok.step);
    }

    // ------------------------------------------------- programs that must fail
    //
    // Every other fixture is a program that must *work*; these must be refused,
    // by both implementations. Stage 1 must report each listed diagnostic, line
    // and column included, and exactly that many; stage 0 must refuse to run the
    // program. Both halves matter, for the reason `fwd_uninit.mpl` exists: a
    // program stage 0 refuses and the checker accepts is one the compiled backend
    // gives a meaning stage 0 never would.
    const reject_step = b.step("test-reject", "Check that programs which must fail are refused by both stages");
    // `stage0 = null` is for a rule stage 0 does not check: BOOTSTRAP §1.3 gives it no
    // static checking, so a program only the checker refuses still runs there. That
    // direction is safe — the compiler is stricter, never more permissive.
    // `driver` is what stage 1 runs: `typecheck.mpl` stops after inference, so a refusal
    // only lowering makes needs `lower_dump.mpl`, which counts `check errors:`.
    for ([_]struct { src: []const u8, stage1: []const []const u8, count: []const u8, stage0: ?[]const u8, driver: []const u8 = "stage1/typecheck.mpl" }{
        .{
            .src = "stage1/fixtures/fwd_uninit.mpl",
            .stage1 = &.{
                "fwd_uninit.mpl:14:1: 'f' is read before the $decl completing its $fwd has run",
                "fwd_uninit.mpl:20:1: 'v' is read before the $decl completing its $fwd has run",
                "fwd_uninit.mpl:23:1: 'v' is read before the $decl completing its $fwd has run",
            },
            .count = "errors: 3\n",
            .stage0 = "is not initialized yet",
        },
        // An overload of templates none of whose candidates fits (STDLIB.md, P7): reported
        // at the use, never at a candidate's failing bound. Matched in pieces, since the
        // overload renders as its templates' identities.
        .{
            .src = "stage1/fixtures/overload_tmpl_none.mpl",
            .stage1 = &.{
                "overload_tmpl_none.mpl:8:16: no candidate of O<",
                "accepts these arguments: none is a template whose bounds hold (§4.8, §4.9)",
                "overload_tmpl_none.mpl:12:13: no candidate of O<",
            },
            .count = "errors: 2\n",
            .stage0 = "$specialize expects a template, found overload",
        },
        // §4.12a: an `$override` only replaces, at a subtype, with props; a template's is
        // written in place and is not overridden again.
        .{
            .src = "stage1/fixtures/override_bad.mpl",
            .stage1 = &.{
                "override_bad.mpl:5:10: 'size' is not a prop of the $override's base",
                "override_bad.mpl:6:10: 'w' is a field of the $override's base",
                "override_bad.mpl:7:10: member 'area' of this $override is []->Str, which is no subtype of the []->Int it replaces",
                "override_bad.mpl:8:10: an $override's override is a block of props only",
                "override_bad.mpl:10:10: 'take' is not a prop of this template's body",
                "override_bad.mpl:12:10: an $override of a template takes its props as a block written in place",
            },
            .count = "errors: 6\n",
            .stage0 = "$override is outside the bootstrap subset",
        },
        // §5.3a's provenance (STORAGE.md): a place this call made may not be returned,
        // stored inside a value, or passed by a tail call.
        .{
            .src = "stage1/fixtures/places.mpl",
            .stage1 = &.{
                "places.mpl:11:12: this function's result holds frame storage made in this call (&Int)",
                "places.mpl:12:12: this function's result holds frame storage made in this call (&mut Int)",
                "places.mpl:13:12: this function's result holds frame storage made in this call (a reference captured by a closure)",
                "places.mpl:18:18: storage cannot hold a place",
                "places.mpl:24:60: this tail call passes $new storage made in this call",
                "places.mpl:32:55: this tail call makes a trait object referring to storage of this call",
                "places.mpl:34:20: storage cannot hold a place: this trait object would refer to frame storage",
                "places.mpl:42:15: this function's result holds frame storage made in this call",
                "places.mpl:46:15: this function's result holds frame storage made in this call",
            },
            .count = "errors: 9\n",
            .stage0 = null,
        },
        .{
            .src = "stage1/fixtures/defer_bad.mpl",
            .stage1 = &.{
                "defer_bad.mpl:3:31: $defer is a block item: it belongs directly in a block's items",
            },
            .count = "errors: 1\n",
            .stage0 = "$defer is a block item: it belongs directly in a block's items",
        },
        .{
            .src = "stage1/fixtures/short_value.mpl",
            .stage1 = &.{
                "short_value.mpl:10:39: an omitted argument needs its default, and this callee is a function value whose definition is not known here (§3.4): pass every argument",
                "short_value.mpl:11:63: an omitted argument needs its default, and this callee is a function value whose definition is not known here (§3.4): pass every argument",
                "short_value.mpl:13:30: an omitted argument needs its default, and this callee is a function value whose definition is not known here (§3.4): pass every argument",
                "short_value.mpl:15:33: an omitted argument needs its default, and this callee is a function value whose definition is not known here (§3.4): pass every argument",
                "short_value.mpl:16:31: an omitted argument needs its default, and this callee is a function value whose definition is not known here (§3.4): pass every argument",
            },
            .count = "errors: 5\n",
            .stage0 = null,
        },
        // A short call to a `$func` prop whose omitted default reads its frame (§3.4).
        .{
            .src = "stage1/fixtures/short_frame.mpl",
            .stage1 = &.{
                "short_frame.mpl:13:13: an omitted argument's default reads 'p', a binding of the frame its function is written in, and a short call evaluates it in a wrapper of its own, which has no such frame (§3.4): pass every argument",
                "short_frame.mpl:15:11: an omitted argument's default reads 'p', a binding of the frame its function is written in, and a short call evaluates it in a wrapper of its own, which has no such frame (§3.4): pass every argument",
                "short_frame.mpl:16:11: an omitted argument's default reads 'p', a binding of the frame its function is written in, and a short call evaluates it in a wrapper of its own, which has no such frame (§3.4): pass every argument",
                "short_frame.mpl:25:11: an omitted argument's default reads 'p', a binding of the frame its function is written in, and a short call evaluates it in a wrapper of its own, which has no such frame (§3.4): pass every argument",
            },
            .count = "errors: 4\n",
            .stage0 = null,
        },
        .{
            .src = "stage1/fixtures/dead_arm.mpl",
            .stage1 = &.{
                "dead_arm.mpl:10:3: this arm's pattern, {tag=s\"conz\",}, is no member of the scrutinee's type, so the arm can never run",
            },
            .count = "errors: 1\n",
            .stage0 = null,
        },
        .{
            .src = "stage1/fixtures/free_bad.mpl",
            .stage1 = &.{
                "free_bad.mpl:18:13: $free needs allocated storage it may end, found &Int",
                "free_bad.mpl:23:13: $free needs allocated storage it may end, found &^const Int",
                "free_bad.mpl:29:13: the allocator in scope cannot serve $free: its free is [Int]->(), which must take an address and a size",
                "free_bad.mpl:34:13: this storage came from another allocator than the one in scope here",
                "free_bad.mpl:39:33: an $alloc block's deferral runs at $free, after this frame is gone: it may name only the block's fields and globals",
            },
            .count = "errors: 5\n",
            .stage0 = null,
        },
        // DEFER.md step 4's routing, which only lowering used to check: a `$free` of storage
        // whose allocator is unknown or another, and a freeing callee given storage that is
        // not known to be the root's.
        .{
            .src = "stage1/fixtures/free_route.mpl",
            .stage1 = &.{
                "free_route.mpl:14:22: $free needs a name this function bound from an $alloc",
                "free_route.mpl:17:20: $free needs a name this function bound from an $alloc",
                "free_route.mpl:20:47: this storage came from another allocator than the one in scope here",
                "free_route.mpl:25:26: the callee frees this argument through the root allocator, but it came from another",
                "free_route.mpl:28:70: the callee frees this argument, so where it came from must be known here",
                "free_route.mpl:32:26: the callee frees this argument, so where it came from must be known here",
                "free_route.mpl:37:13: $free needs a name this function bound from an $alloc",
            },
            .count = "errors: 7\n",
            .stage0 = null,
        },
        // A local spelled like a top-level name is no global: §4.16 rule 2's callback, a
        // trait object's frame (§5.3a) and an `$alloc` block's deferral ask the scope.
        .{
            .src = "stage1/fixtures/topname_scope.mpl",
            .stage1 = &.{
                "topname_scope.mpl:12:35: a callback passed to C must be capture-free (§4.16 rule 2): c captures helper",
                "topname_scope.mpl:15:10: this function's result holds frame storage made in this call",
                "topname_scope.mpl:21:33: an $alloc block's deferral runs at $free, after this frame is gone",
            },
            .count = "errors: 3\n",
            .stage0 = null,
        },
        // A root-block name and a callback's literal are asked of the scope too: a local `add`
        // is a capture, and a parameter `cb` is no `$decl` of the top-level literal.
        .{
            .src = "stage1/fixtures/capture_scope.mpl",
            .stage1 = &.{
                "capture_scope.mpl:10:35: a callback passed to C must be capture-free (§4.16 rule 2): c captures add",
                "capture_scope.mpl:13:81: a callback passed to C must be capture-free (§4.16 rule 2): cb is not a $decl of a $func literal",
                "capture_scope.mpl:15:15: a $prop's $func may not capture 'add': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
            },
            .count = "errors: 3\n",
            .stage0 = null,
        },
        // Lowering's diagnostics name their own file: a base template's line spliced by an
        // `$override` is mapped back from `Pa.ov_shift` (§4.12a), and a module member's
        // used to be reported against the entry file.
        .{
            .src = "stage1/fixtures/override_diag.mpl",
            .stage1 = &.{
                "override_diag_util.mpl:9:39: $free needs a name this function bound from an $alloc",
                "override_diag_util.mpl:11:38: this template's value specialises itself where it is evaluated",
            },
            .count = "check errors: 2\n",
            .stage0 = "$override is outside the bootstrap subset",
            .driver = "stage1/lower_dump.mpl",
        },
        // Two `$override`s deep: one shift down is the template overridden, two is the base.
        .{
            .src = "stage1/fixtures/override2_diag.mpl",
            .stage1 = &.{
                "override_diag_util.mpl:9:39: $free needs a name this function bound from an $alloc",
                "override2_dmid.mpl:5:39: $free needs a name this function bound from an $alloc",
            },
            .count = "check errors: 3\n",
            .stage0 = "$override is outside the bootstrap subset",
            .driver = "stage1/lower_dump.mpl",
        },
        // §4.10: a `$func` prop may not capture, directly, through a template it names, or as
        // a candidate or member the value evaluates.
        // Which names are runtime is a question stage 0 cannot ask, and it runs the file.
        .{
            .src = "stage1/fixtures/prop_cap.mpl",
            .stage1 = &.{
                "prop_cap.mpl:10:25: a $prop's $func may not capture 'base': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
                "prop_cap.mpl:13:25: a $prop's $func may not capture 'base', read by template 'w': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
                "prop_cap.mpl:26:13: a $prop's $func may not capture 'base': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
                "prop_cap.mpl:27:13: a $prop's $func may not capture 'base': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
            },
            .count = "errors: 4\n",
            .stage0 = null,
        },
        // A top-level name is a global only where it is in scope: another module's, an
        // `$override`'s hidden one, and a top-level block's `$decl` are not.
        .{
            .src = "stage1/fixtures/prop_cap_scope.mpl",
            .stage1 = &.{
                "prop_cap_scope.mpl:12:15: a $prop's $func may not capture 'helper': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
                "prop_cap_scope.mpl:13:32: a $prop's $func may not capture 'helper': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
                "prop_cap_scope.mpl:19:13: a $prop's $func may not capture 'y': a prop is compile-time and its value part of the block's type (§4.10), and a capture is a runtime value",
            },
            .count = "errors: 3\n",
            .stage0 = null,
        },
        .{
            .src = "stage1/fixtures/tmpl_escape.mpl",
            .stage1 = &.{
                "tmpl_escape.mpl:5:13: this function's result holds frame storage made in this call (&block)",
            },
            .count = "errors: 1\n",
            .stage0 = null,
        },
        .{
            .src = "stage1/fixtures/ctor_bad.mpl",
            .stage1 = &.{
                "ctor_bad.mpl:16:48: this constructor's deferral reads 'k', which ends when the constructor returns",
                "ctor_bad.mpl:17:36: a constructor's block may not hold a $try",
                "ctor_bad.mpl:18:12: this function chooses between constructions",
                "ctor_bad.mpl:19:12: this function's result holds frame storage made in this call (&block)",
                "ctor_bad.mpl:20:12: this function's result holds frame storage made in this call (&block)",
                "ctor_bad.mpl:21:33: this tail call passes $new storage made in this call",
                "ctor_bad.mpl:22:31: this calls a constructing function through a value",
                "ctor_bad.mpl:24:21: this calls a constructing function through an $overload",
                "ctor_bad.mpl:27:13: this constructor is called before its type is known",
            },
            .count = "errors: 9\n",
            .stage0 = null,
        },
        .{
            .src = "stage1/fixtures/owner_bad.mpl",
            .stage1 = &.{
                "owner_bad.mpl:4:13: 'ret2' holds a place owned by this block, which ends here: an alias may not outlive its owner",
            },
            .count = "errors: 1\n",
            .stage0 = null,
        },
    }) |bad| {
        const s1 = b.addRunArtifact(runner);
        s1.addArgs(&.{ "--run", bad.driver, bad.src });
        s1.setCwd(b.path("."));
        s1.has_side_effects = true;
        for (bad.stage1) |m| s1.expectStdOutMatch(m);
        s1.expectStdOutMatch(bad.count);
        reject_step.dependOn(&s1.step);
        test_step.dependOn(&s1.step);

        if (bad.stage0) |msg| {
            const s0 = b.addRunArtifact(runner);
            s0.addArgs(&.{ "--run", bad.src });
            s0.setCwd(b.path("."));
            s0.has_side_effects = true;
            s0.expectStdErrMatch(msg);
            s0.expectExitCode(1);
            reject_step.dependOn(&s0.step);
            test_step.dependOn(&s0.step);
        }
    }


    // ------------------------------------------------- §9.1's list of outputs
    //
    // `emit` answers one output per module (§9.1), and the point of that is a file
    // per source module that compiles on its own — so this builds a program the way
    // a real build would: write the outputs, compile each *separately*, link them.
    //
    // It is the only step that can find a linkage mistake. `test-emit` concatenates
    // everything into one translation unit, where a symbol that should have been
    // external is indistinguishable from one that is `static`; `verify` cannot see
    // linkage at all. Three bugs were found exactly here, all of them references
    // `mpl_init` makes that no walk over function bodies can see.
    //
    // No `#include` is emitted — §9 makes the build a program, so how a target
    // invokes its C compiler is the build's business — hence `-include mpl.h` below.
    //
    // The expected file list is declared rather than globbed, which also pins the
    // partition: if `emit` stopped giving a module its own output, this fails.
    const split_step = b.step("test-split", "Build a program from one C file per module");
    {
        // The writing driver, compiled: §8's `write_file` is emitted, so a compiled
        // driver can put each output where its `path` says. Under stage 0 it could
        // not — `--run` never calls `main`, which is where a compiled driver's work
        // has to live, or the link fails for want of `main`.
        const ef_emit = std.Build.Step.Run.create(b, "mplc emits the writing driver");
        ef_emit.addFileArg(mplc_bin);
        ef_emit.addArg("stage1/emit_files.mpl");
        ef_emit.setCwd(b.path("."));
        ef_emit.has_side_effects = true;
        const ef_c = ef_emit.captureStdOut(.{ .basename = "emit_files.c" });
        const ef_cc = b.addSystemCommand(&.{ "cc", "-O2", "-w", "-o" });
        const ef_bin = ef_cc.addOutputFileArg("emit_files");
        ef_cc.addFileArg(ef_c);

        for ([_]struct { src: []const u8, want: []const u8, mods: []const []const u8 }{
            // Two modules and a global read across the boundary.
            .{ .src = "stage1/fixtures/import.mpl", .want = "57\n", .mods = &.{"import_util"} },
            // §3.3's effects, which is what per-module initialisers are for: each
            // module runs its own, in §4.10's order, and the answer pins the order.
            // Three outputs, not two: `effect_util` imports the prelude, so that is a
            // module of this program too. Declaring the list rather than globbing is what
            // caught the omission — `prelude.c` was written and never compiled, and the
            // link failed on `mpl_fprelude_4`.
            .{ .src = "stage1/fixtures/effect.mpl", .want = "46\n", .mods = &.{ "prelude", "effect_util" } },
            // A cycle between two module members (§5.5), so each is named from the
            // other's output.
            .{ .src = "stage1/fixtures/mutual_import.mpl", .want = "5\n", .mods = &.{"mutual_util"} },
            // The same cycle, through each other's function in the result: one `μ`, named
            // from both outputs.
            .{ .src = "stage1/fixtures/mu_group.mpl", .want = "2143\n", .mods = &.{"mu_group_util"} },
            // A module's resource registered with the root's `defer_at` in its output and
            // freed from the entry's, through the side table only `main.c` defines.
            .{ .src = "stage1/fixtures/open_mod.mpl", .want = "52431\n", .mods = &.{"open_util"} },
            // A module's record is a static in the importer's output initialised from
            // globals in the module's, so this is the fixture where that has to link.
            .{ .src = "stage1/fixtures/module_value.mpl", .want = "41\n", .mods = &.{ "modval_inner", "modval_util" } },
            // A prop read off a parameter is lowered where it is written and called from
            // the reader's output, so this is where that has to link.
            .{ .src = "stage1/fixtures/prop_param.mpl", .want = "98\n", .mods = &.{ "prelude", "prop_param_util" } },
            // A wrapper lives in its callee's output and is called from the caller's.
            .{ .src = "stage1/fixtures/defaults.mpl", .want = "247\n", .mods = &.{ "prelude", "defaults_util" } },
            // A module's initialiser is its own output's, so source order has to hold there.
            .{ .src = "stage1/fixtures/init_fwd.mpl", .want = "22\n", .mods = &.{"init_fwd_util"} },
            // §6's tables are static in the shared header, and their shims call members
            // defined in the module's own output — so they must be external there.
            .{ .src = "stage1/fixtures/traits_split.mpl", .want = "49\n", .mods = &.{"traits_util"} },
            // DEFER.md example 12: the exit stack is shared state, defined beside `main`, and
            // a module registers on it from its own output.
            .{ .src = "stage1/fixtures/top_defer.mpl", .want = "tmp init main 18\nc b a e1 u2 u1\n",
               .mods = &.{"top_defer_util"} },
            // An `$import` calls its module's initialiser, which another output defines.
            .{ .src = "stage1/fixtures/import_order.mpl", .want = "e1 m1 i m2 e2 5\nde2 dm di de1 ",
               .mods = &.{ "import_order_inner", "import_order_util" } },
            .{ .src = "stage1/fixtures/tscalar.mpl", .want = "47\n", .mods = &.{"tscalar_util"} },
            // A function adapter is `static` in the output that coerces, named after its
            // module, so each output carries its own and the program links either way.
            .{ .src = "stage1/fixtures/fn_coerce.mpl", .want = "1243586789\n", .mods = &.{"fn_coerce_util"} },
            // A trait adapter is static in the shared header and calls a member's shim there,
            // whose member is defined in the module's output.
            .{ .src = "stage1/fixtures/trait_coerce.mpl", .want = "7345869\n", .mods = &.{"trait_coerce_util"} },
            // §4.12a: a template made by `$override` is emitted where the `$override` is, so
            // its spliced body names the base's module members from another output.
            .{ .src = "stage1/fixtures/override.mpl", .want = "4 33 30 4 4 2 7 1400 1010 101 101\n",
               .mods = &.{"override_util"} },
            // Three levels across two files: the spliced bodies are emitted where each
            // `$override` is, and name the module's members across outputs.
            .{ .src = "stage1/fixtures/override2.mpl", .want = "31410\n", .mods = &.{"override2_util"} },
            // A wrapper table is static in the output that coerces, named after its module.
            .{ .src = "stage1/fixtures/trait_wrap.mpl", .want = "534168\n", .mods = &.{"trait_wrap_util"} },
            // An intrinsic named as a value in two outputs, each with its generated wrapper,
            // and a pair made in the module called from the entry's file.
            .{ .src = "stage1/fixtures/prim_value.mpl", .want = "32555871\n", .mods = &.{"prim_value_util"} },
            // One module under two spellings is one output, not two defining its functions.
            .{ .src = "stage1/fixtures/import_spell.mpl", .want = "i 5\n", .mods = &.{ "import_spell_inner", "import_spell_util" } },
        }) |fx| {
            const write = std.Build.Step.Run.create(b, "emit one output per module");
            write.addFileArg(ef_bin);
            write.addArg(fx.src);
            const dir = write.addOutputDirectoryArg("split");
            write.setCwd(b.path("."));
            write.has_side_effects = true;

            const link = b.addSystemCommand(&.{ "cc", "-o" });
            const prog = link.addOutputFileArg("prog");

            // Every module's output, plus the entry file's, each its own translation
            // unit. `-w` because a compiler emits statics nothing calls, and here
            // every file sees the whole header.
            var names = std.ArrayList([]const u8).initCapacity(b.allocator, fx.mods.len + 1) catch @panic("OOM");
            for (fx.mods) |m| names.appendAssumeCapacity(b.fmt("{s}.c", .{m}));
            names.appendAssumeCapacity("main.c");
            for (names.items) |name| {
                const cc = b.addSystemCommand(&.{ "cc", "-O0", "-w", "-include" });
                cc.addFileArg(dir.path(b, "mpl.h"));
                cc.addArgs(&.{ "-c", "-o" });
                const obj = cc.addOutputFileArg(b.fmt("{s}.o", .{name}));
                cc.addFileArg(dir.path(b, name));
                link.addFileArg(obj);
            }

            const run_split = std.Build.Step.Run.create(b, "run the separately built program");
            run_split.addFileArg(prog);
            run_split.expectStdOutEqual(fx.want);
            split_step.dependOn(&run_split.step);
            test_step.dependOn(&run_split.step);
        }
    }

    // ------------------------------------------- a module's output is its own
    //
    // §4.14 makes a projection onto a module the only way to name a function across
    // that edge, so a function's C linkage is decidable from the function alone —
    // which is what makes a module's emitted text a function of its own source, and
    // therefore cacheable per module. This is the check on that claim: two programs
    // importing one module, differing only in which of its members the *entry file*
    // calls, must produce a byte-identical output for it.
    //
    // It replaces a rule that asked whether some other module named a function. That
    // was finer — fewer exports — and being finer was the defect: `stable_b` calling
    // one extra prelude member flipped it from `static` to external and rewrote
    // `prelude.c` from outside prelude. `test-split` cannot see this (it only asks
    // whether the program links) and neither can `test-emit` (it concatenates).
    //
    // Under stage 0, not `mplc`, because it is `stage1/` that is being checked and a
    // committed binary predates the change by construction.
    const stable_step = b.step("test-stable", "One module, three programs, identical output");
    {
        var outs: [3]std.Build.LazyPath = undefined;
        for ([_][]const u8{ "stable_a", "stable_b", "stable_c" }, 0..) |name, i| {
            const one = std.Build.Step.Run.create(b, b.fmt("emit prelude.c for {s}", .{name}));
            one.addFileArg(runner.getEmittedBin());
            one.addArgs(&.{ "--run", "stage1/emit_one.mpl", b.fmt("stage1/fixtures/{s}.mpl", .{name}), "prelude.c" });
            one.setCwd(b.path("."));
            one.has_side_effects = true;
            outs[i] = one.captureStdOut(.{ .basename = b.fmt("{s}.prelude.c", .{name}) });
        }
        // `stable_b` differs from `stable_a` only in which prelude member the entry
        // file calls, which is the **linkage** property. `stable_c` reaches the prelude
        // *through another module* instead of directly, which is the **naming**
        // property: every counter in lowering is at a different value by the time the
        // prelude is lowered, so this fails for any identity still drawn from one.
        for ([_]usize{ 1, 2 }) |i| {
            const same = b.addSystemCommand(&.{"cmp"});
            same.addFileArg(outs[0]);
            same.addFileArg(outs[i]);
            stable_step.dependOn(&same.step);
            test_step.dependOn(&same.step);
        }
    }

    // ------------------------------------ a compile-time identity is its source
    //
    // §4.10's prop values and §4.9's template ids end up in a module's *interface*,
    // so a per-module cache can only hit if they are a function of the source rather
    // than of what the checker happened to reach first. `ct_id` makes them so; this
    // is the check.
    //
    // **One module, two importing programs.** `ifm.mpl` carries both identities
    // inference mints — a `$func`-valued prop's `cv_opaque` and a `$template`'s id —
    // and both entry files import it; `iface_d.mpl` first imports `ifx.mpl`, which
    // mints some of each. Its serialised interface must come out byte-identical.
    //
    // An earlier version compared a prop declared in *each* of the two fixtures, which
    // cannot work: an identity derives from the file's short name, so two files differ
    // by design. It passed only because `check_source`'s arguments were swapped, which
    // made `cx.file` the shared directory — the guard was an artifact of the same bug
    // it was meant to catch. Against the pre-fix compiler this one reads `listM16 o28`
    // against `listM11 o33`; with the fix the two interfaces are equal.
    //
    // Reading it is possible at all because an `$import`'s field type *is* the
    // module's interface — `iface_dump.mpl` prints that field and nothing else, since
    // the output is compared byte for byte.
    const iface_step = b.step("test-iface", "A compile-time identity is independent of load order");
    {
        var ids: [2]std.Build.LazyPath = undefined;
        for ([_][]const u8{ "iface_c", "iface_d" }, 0..) |name, i| {
            const dump = b.addRunArtifact(runner);
            dump.addArgs(&.{ "--run", "stage1/iface_dump.mpl", b.fmt("stage1/fixtures/{s}.mpl", .{name}), "M" });
            dump.setCwd(b.path("."));
            dump.has_side_effects = true;
            ids[i] = dump.captureStdOut(.{ .basename = b.fmt("{s}.id", .{name}) });
        }
        const same = b.addSystemCommand(&.{"cmp"});
        same.addFileArg(ids[0]);
        same.addFileArg(ids[1]);
        iface_step.dependOn(&same.step);
        test_step.dependOn(&same.step);
    }


    // **The guard against `bootstrap/mplc.c` rotting.** The committed C has to be
    // what the compiler it builds emits for its own source. Change `stage1/` and
    // forget to regenerate, and this is what says so — otherwise the committed C
    // silently drifts behind the tree it claims to be.
    {
        const emit = std.Build.Step.Run.create(b, "mplc emits its own source");
        emit.addFileArg(mplc_bin);
        emit.addArg("stage1/mplc.mpl");
        emit.setCwd(b.path("."));
        // stage-1 sources are read at *run* time, so a cached run would compile
        // the previous compiler — the same reason the suites above say this.
        emit.has_side_effects = true;
        const fresh = emit.captureStdOut(.{ .basename = "mplc.c" });
        const same = b.addSystemCommand(&.{"cmp"});
        same.addFileArg(fresh);
        same.addFileArg(b.path("bootstrap/mplc.c"));
        s2_step.dependOn(&same.step);
        test_step.dependOn(&same.step);
    }

    // §9.1's `link`: `mplc <file> -o <exe>` writes the C beside the executable and
    // runs `cc` on it through BOOTSTRAP §2's `run`, so the executable is built by the
    // compiler and not by this file. Four fixtures — one imports a module, one needs
    // its C host, passed as `mplc`'s trailing `cc` arguments, one finds its modules
    // through §4.14's search roots (`-L`, `pre`) — and a program that does not link
    // must make `mplc` fail.
    // The standard library (STDLIB.md): each module's test, compiled by `mplc` with the
    // repository as its search root — `std/` modules import one another as "std/core",
    // and §4.14's roots are how a program finds them — run plain and under ASan with
    // UBSan. Compiled-only, since the library is outside stage 0's subset (STDLIB.md, P5).
    // A test's `main` answers how many checks passed and a failing one panics, so the
    // count is the verdict and a run that stopped early cannot match it.
    const std_step = b.step("test-std", "Build and run the standard library's tests");
    for ([_]struct { src: []const u8, want: []const u8 }{
        .{ .src = "std/core_test.mpl", .want = "17\n" },
        .{ .src = "std/list_test.mpl", .want = "28\n" },
        .{ .src = "std/seq_test.mpl", .want = "36\n" },
        .{ .src = "std/str_test.mpl", .want = "30\n" },
        .{ .src = "std/vec_test.mpl", .want = "26\n" },
        .{ .src = "std/map_test.mpl", .want = "16\n" },
        .{ .src = "std/fmt_test.mpl", .want = "27\n" },
        .{ .src = "std/io_test.mpl", .want = "29\n" },
        .{ .src = "std/mem_test.mpl", .want = "10\n" },
        .{ .src = "std/result_test.mpl", .want = "10\n" },
        .{ .src = "std/json_test.mpl", .want = "18\n" },
    }) |fx| {
        for ([_]bool{ false, true }) |asan| {
            const build_exe = std.Build.Step.Run.create(b, if (asan) "mplc std test (asan)" else "mplc std test");
            build_exe.addFileArg(mplc_bin);
            build_exe.addArgs(&.{ fx.src, "-L", ".", "-o" });
            const exe_out = build_exe.addOutputFileArg("prog");
            if (asan) build_exe.addArgs(&.{ "-fsanitize=address,undefined", "-fno-omit-frame-pointer" });
            build_exe.setCwd(b.path("."));
            build_exe.has_side_effects = true;
            build_exe.expectExitCode(0);
            const run_exe = std.Build.Step.Run.create(b, if (asan) "run std test (asan)" else "run std test");
            run_exe.addFileArg(exe_out);
            // The runtime never frees (BOOTSTRAP §3), so leak reports are noise.
            if (asan) run_exe.setEnvironmentVariable("ASAN_OPTIONS", "detect_leaks=0:detect_stack_use_after_return=1");
            run_exe.has_side_effects = true;
            run_exe.expectStdOutEqual(fx.want);
            std_step.dependOn(&run_exe.step);
            test_step.dependOn(&run_exe.step);
        }
    }
    {
        // The runner's failure path: a failing test is named on stderr and the run aborts,
        // so a test file cannot pass by accident.
        const build_exe = std.Build.Step.Run.create(b, "mplc std/test_test.mpl");
        build_exe.addFileArg(mplc_bin);
        build_exe.addArgs(&.{ "std/test_test.mpl", "-L", ".", "-o" });
        const exe_out = build_exe.addOutputFileArg("prog");
        build_exe.setCwd(b.path("."));
        build_exe.has_side_effects = true;
        build_exe.expectExitCode(0);
        const run_exe = std.Build.Step.Run.create(b, "a failing std test aborts");
        run_exe.addFileArg(exe_out);
        run_exe.has_side_effects = true;
        run_exe.addCheck(.{ .expect_stderr_match = "FAIL broken" });
        run_exe.addCheck(.{ .expect_stderr_match = "1 of 3 checks failed" });
        run_exe.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
        std_step.dependOn(&run_exe.step);
        test_step.dependOn(&run_exe.step);
    }

    // The language server (lsp/morphl_lsp.mpl): `zig build lsp` installs `morphl-lsp`, built
    // by `mplc` with the repository and `stage1/` as search roots — it imports the compiler
    // as `compiler`, so the compiler's own imports resolve the same way in both passes.
    // `test-lsp` plays a recorded session (`lsp/test/session.py` writes it) and the replies
    // must equal `lsp/test/session.out` byte for byte. Each check runs the binary again as a
    // child (`/proc/self/exe --check …`), so this tests the child too.
    const lsp_step = b.step("lsp", "Build the language server, zig-out/bin/morphl-lsp");
    const lsp_test_step = b.step("test-lsp", "Play a recorded LSP session through morphl-lsp");
    {
        const build_lsp = std.Build.Step.Run.create(b, "mplc lsp/morphl_lsp.mpl");
        build_lsp.addFileArg(mplc_bin);
        build_lsp.addArgs(&.{ "lsp/morphl_lsp.mpl", "-L", ".", "-L", "stage1", "-o" });
        const lsp_bin = build_lsp.addOutputFileArg("morphl-lsp");
        build_lsp.setCwd(b.path("."));
        build_lsp.has_side_effects = true;
        build_lsp.expectExitCode(0);
        lsp_step.dependOn(&b.addInstallBinFile(lsp_bin, "morphl-lsp").step);
        const session = std.Build.Step.Run.create(b, "an LSP session");
        session.addFileArg(lsp_bin);
        session.setStdIn(.{ .lazy_path = b.path("lsp/test/session.in") });
        session.has_side_effects = true;
        session.expectExitCode(0);
        const replies = session.captureStdOut(.{ .basename = "session.out" });
        const same = b.addSystemCommand(&.{"cmp"});
        same.addFileArg(replies);
        same.addFileArg(b.path("lsp/test/session.out"));
        lsp_test_step.dependOn(&same.step);
        test_step.dependOn(&same.step);
    }

    const link_step = b.step("test-link", "mplc -o builds a working executable");
    for ([_]struct { src: []const u8, want: []const u8, extra: []const []const u8 = &.{},
                     pre: []const []const u8 = &.{} }{
        .{ .src = "stage1/fixtures/fact.mpl", .want = "3628800\n" },
        .{ .src = "stage1/fixtures/import.mpl", .want = "57\n" },
        .{ .src = "stage1/fixtures/ffi.mpl", .want = "11117493\n",
           .extra = &.{"stage1/fixtures/ffi_host.c"} },
        .{ .src = "stage1/fixtures/libroot.mpl", .want = "23\n",
           .pre = &.{ "-L", "stage1/fixtures/lib" } },
    }) |fx| {
        const build_exe = std.Build.Step.Run.create(b, "mplc -o");
        build_exe.addFileArg(mplc_bin);
        build_exe.addArg(fx.src);
        build_exe.addArgs(fx.pre);
        build_exe.addArg("-o");
        const exe_out = build_exe.addOutputFileArg("prog");
        build_exe.addArgs(fx.extra);
        build_exe.setCwd(b.path("."));
        build_exe.has_side_effects = true;
        build_exe.expectExitCode(0);
        const run_exe = std.Build.Step.Run.create(b, "run what mplc linked");
        run_exe.addFileArg(exe_out);
        run_exe.has_side_effects = true;
        run_exe.expectStdOutEqual(fx.want);
        link_step.dependOn(&run_exe.step);
        test_step.dependOn(&run_exe.step);
    }
    {
        // An extern C does not define: `cc` fails, so `link` reports and `mplc` aborts.
        const bad = std.Build.Step.Run.create(b, "mplc -o on a program that does not link");
        bad.addFileArg(mplc_bin);
        bad.addArgs(&.{ "stage1/fixtures/unlinked.mpl", "-o" });
        _ = bad.addOutputFileArg("prog");
        bad.setCwd(b.path("."));
        bad.has_side_effects = true;
        bad.addCheck(.{ .expect_stderr_match = "link: cc exited with status 1" });
        bad.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
        link_step.dependOn(&bad.step);
        test_step.dependOn(&bad.step);
    }
    {
        // Without its search root the same program does not resolve, and says so where it
        // always did: a root is a fallback after the entry's directory, never a substitute.
        const noroot = std.Build.Step.Run.create(b, "mplc without -L");
        noroot.addFileArg(mplc_bin);
        noroot.addArg("stage1/fixtures/libroot.mpl");
        noroot.setCwd(b.path("."));
        noroot.has_side_effects = true;
        noroot.addCheck(.{ .expect_stderr_match = "cannot read the file for $import \"std/lr_twice\"" });
        noroot.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
        link_step.dependOn(&noroot.step);
        test_step.dependOn(&noroot.step);
    }

    // `mplc` reports a non-fatal diagnostic on stderr and keeps stdout the C. It could
    // not before — §8 gave a program stdout and `panic`, and a warning on stdout would
    // corrupt the artifact — so emit's diagnostics were computed and dropped. A library
    // is the case every build hits: "no top-level `$decl` named `main`" is not an error
    // for one, and must arrive as a warning with exit 0.
    {
        const warn = std.Build.Step.Run.create(b, "mplc warns on stderr");
        warn.addFileArg(mplc_bin);
        warn.addArg("stage1/fixtures/import_util.mpl");
        warn.setCwd(b.path("."));
        warn.has_side_effects = true;
        warn.expectStdErrMatch("stage1/fixtures/import_util.mpl: warning: no top-level $decl named 'main'\n");
        warn.expectExitCode(0);
        s2_step.dependOn(&warn.step);
        test_step.dependOn(&warn.step);
    }

    // ...and an emit *error* is fatal, as a check error is: it means the C is wrong, and
    // it used to be a warning too, so `mplc` wrote that C and exited 0. The note still
    // comes out first.
    {
        const fail = std.Build.Step.Run.create(b, "mplc fails on an emit error");
        fail.addFileArg(mplc_bin);
        fail.addArg("stage1/fixtures/emit_err.mpl");
        fail.setCwd(b.path("."));
        fail.has_side_effects = true;
        fail.addCheck(.{ .expect_stderr_match = "stage1/fixtures/emit_err.mpl: warning: no top-level $decl named 'main'\n" });
        fail.addCheck(.{ .expect_stderr_match = "emit: 1 error(s), first at stage1/fixtures/emit_err.mpl: $extern \"long labs(long, long)\": the C prototype and the signature take different numbers of parameters (§4.16)" });
        fail.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
        s2_step.dependOn(&fail.step);
        test_step.dependOn(&fail.step);
    }

    // Every library module, emitted on its own as the entry file, is C that `cc` accepts.
    // A program uses only part of a module, so a type it lays out but never reads through
    // is the case no fixture reaches: `ir.mpl` alone has list cells whose `tail` type
    // nothing interned, which emit spelled `int64_t` silently and, once that was an error,
    // refused. `-fsyntax-only` is enough: the question is whether the C is well-typed.
    const libs_step = b.step("test-libs", "Emit each library module alone and check the C compiles");
    for ([_][]const u8{
        "stage1/prelude.mpl", "stage1/lexer.mpl", "stage1/parser.mpl", "stage1/types.mpl",
        "stage1/tyio.mpl",    "stage1/ir.mpl",    "stage1/infer.mpl",  "stage1/verify.mpl",
        "stage1/lower.mpl",   "stage1/emit.mpl",  "stage1/compiler.mpl",
        "std/core.mpl",       "std/fmt.mpl",      "std/io.mpl",        "std/json.mpl",
        "std/list.mpl",       "std/map.mpl",      "std/mem.mpl",       "std/result.mpl",
        "std/seq.mpl",        "std/str.mpl",      "std/test.mpl",      "std/vec.mpl",
    }) |src| {
        const emit = std.Build.Step.Run.create(b, b.fmt("mplc {s} alone", .{src}));
        emit.addFileArg(mplc_bin);
        emit.addArgs(&.{ src, "-L", "." });
        emit.setCwd(b.path("."));
        emit.has_side_effects = true;
        const c_file = emit.captureStdOut(.{ .basename = "lib.c" });
        _ = emit.captureStdErr(.{});
        emit.expectExitCode(0);
        const cc = b.addSystemCommand(&.{ "cc", "-fsyntax-only", "-Wall", "-Wno-unused-function",
            "-Wno-unused-but-set-variable", "-Werror" });
        cc.addFileArg(c_file);
        cc.has_side_effects = true;
        cc.expectExitCode(0);
        libs_step.dependOn(&cc.step);
        test_step.dependOn(&cc.step);
    }

    // ---------------------------------------------------------------- paranoid
    //
    // `T.same` answers by interned class (INTERNING.md), and a class is only right while
    // each constructor's key mirrors `same_deep` exactly. Nothing else notices if one
    // stops: the answers are wrong only for the pairs a gap merges, and the emitted C stays
    // plausible. So the whole compiler is compiled with every comparison checked against
    // the structural reference, and any **merge** — two types `same_deep` calls different
    // in one class — fails the step, as does any **tie**, two union members of different
    // classes rendering alike, which both answers miss (`same_deep` trusts the union sort).
    // It was shown to bite: with field names dropped from the block key it reported 46,903
    // merges and exited 134, and with the sort key cut to one byte it stopped on ties. About a minute, most of it
    // the reference walks that class comparison exists to avoid.
    const paranoid_step = b.step("test-paranoid", "Check every class comparison against same_deep over the whole compiler");
    {
        const emit = std.Build.Step.Run.create(b, "mplc emits the paranoid driver");
        emit.addFileArg(mplc_bin);
        emit.addArg("stage1/paranoid.mpl");
        emit.setCwd(b.path("."));
        emit.has_side_effects = true;
        const c_file = emit.captureStdOut(.{ .basename = "paranoid.c" });

        const cc = b.addSystemCommand(&.{ "cc", "-O2", "-w", "-o" });
        const bin = cc.addOutputFileArg("paranoid");
        cc.addFileArg(c_file);

        const pz_run = std.Build.Step.Run.create(b, "paranoid over the compiler");
        pz_run.addFileArg(bin);
        pz_run.addArg("stage1/mplc.mpl");
        pz_run.setCwd(b.path("."));
        pz_run.has_side_effects = true;
        pz_run.expectStdOutMatch(" 0 merges, ");
        pz_run.expectExitCode(0);
        paranoid_step.dependOn(&pz_run.step);
        test_step.dependOn(&pz_run.step);
    }

    // ---------------------------------------------- the suites, compiled
    //
    // `test-stage1` runs the morphl suites under the interpreter. This runs the same
    // suites *compiled*: `mplc` emits each one, `cc` builds it, and it runs. That
    // exercises what the interpreter cannot — the compiled front end, which is what
    // `mplc` actually is — on 400-odd checks written for something else, the way
    // `cc` on the whole compiler has repeatedly found what the morphl suites missed.
    // Five of the eight could not even be emitted until §3.4's defaults were supplied
    // at a short call; they were rejected by `verify`.
    //
    // A suite has no `main`: its checks are top-level effects (§3.3), which run from
    // `mpl_init`. So the driver includes the emitted C and supplies a `main` that runs
    // the initialiser — `mpl_init` is `static`, which is why it is an `#include`
    // rather than a second translation unit — and defines `mpl_argc`/`mpl_argv` (and the
    // root's `defer_at` table, DEFER.md), which
    // the runtime declares `extern` and the backend defines only beside a real `main`.
    //
    // A failing check panics, so the exit status is the verdict. The last line is
    // matched too, because a suite that stopped early would also exit 0 and nothing
    // else would say so. It is the suite's final section's line, so a new section at
    // the end of a suite means updating it here.
    const compiled_step = b.step("test-compiled-suites", "Compile each stage-1 suite with mplc and run it");
    for ([_]struct { src: []const u8, last: []const u8 }{
        .{ .src = "stage1/lexer_test.mpl", .last = "all lexer tests passed\n" },
        .{ .src = "stage1/parser_test.mpl", .last = "all parser tests passed\n" },
        .{ .src = "stage1/types_test.mpl", .last = "all class-key tests passed\n" },
        .{ .src = "stage1/infer_test.mpl", .last = "all borrowing tests passed\n" },
        .{ .src = "stage1/ir_test.mpl", .last = "all typed-tree tests passed\n" },
        .{ .src = "stage1/lower_test.mpl", .last = "all lowering tests passed\n" },
        .{ .src = "stage1/emit_test.mpl", .last = "all C backend tests passed\n" },
        .{ .src = "stage1/compiler_test.mpl", .last = "all pipeline tests passed\n" },
    }) |suite| {
        const emit = std.Build.Step.Run.create(b, "mplc emits the suite");
        emit.addFileArg(mplc_bin);
        emit.addArg(suite.src);
        emit.setCwd(b.path("."));
        emit.has_side_effects = true;
        const c_file = emit.captureStdOut(.{ .basename = "suite.c" });

        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(c_file, "suite.c");
        const driver = wf.add("main.c",
            \\#include "suite.c"
            \\int mpl_argc = 0;
            \\char **mpl_argv = 0;
            \\mpl_fin *mpl_fins = 0;
            \\int64_t mpl_nfins = 0;
            \\int64_t mpl_capfins = 0;
            \\mpl_fun *mpl_exits = 0;
            \\int64_t mpl_nexits = 0;
            \\int64_t mpl_capexits = 0;
            \\int main(int argc, char **argv) {
            \\  mpl_argc = argc;
            \\  mpl_argv = argv;
            \\  mpl_init();
            \\  return 0;
            \\}
            \\
        );

        // -O0: these are big translation units (a suite imports the module it tests
        // and that module's whole closure), and the run is seconds either way.
        const cc = b.addSystemCommand(&.{ "cc", "-O0", "-w", "-o" });
        const bin = cc.addOutputFileArg("suite");
        cc.addFileArg(driver);

        const run_suite = std.Build.Step.Run.create(b, "run the compiled suite");
        run_suite.addFileArg(bin);
        run_suite.setCwd(b.path("."));
        run_suite.has_side_effects = true;
        run_suite.expectExitCode(0);
        run_suite.expectStdOutMatch(suite.last);
        compiled_step.dependOn(&run_suite.step);
        test_step.dependOn(&run_suite.step);
    }

    // `tyio` writes a type down and reads it back, which is what a per-module
    // interface cache rests on. The property is checked against *real* type tables
    // rather than hand-written cases: a lowered module interns the μ types, the big
    // unions, the de Bruijn binders and the prop-bearing blocks that only arise from
    // real source, and `T.same` is the right equality because `intern` keys on it.
    //
    // Compiled, like the suites above, and built once: under stage 0 `emit.mpl` alone
    // took 88s and was the slowest step in `zig build test`, where compiled the three
    // modules below take ~16s together, `lower.mpl`'s 1,233 types included. Chosen for
    // coverage: `types.mpl` has the recursive type language, `emit.mpl` and `lower.mpl`
    // the widest tables. A failed round trip panics, so the exit status is the verdict;
    // it used to print FAIL and exit 0, which hid the `$overload` sorting bug in `tyio`.
    {
        const emit = std.Build.Step.Run.create(b, "mplc emits tyio_test");
        emit.addFileArg(mplc_bin);
        emit.addArg("stage1/tyio_test.mpl");
        emit.setCwd(b.path("."));
        emit.has_side_effects = true;
        const c_file = emit.captureStdOut(.{ .basename = "tyio_test.c" });

        const wf = b.addWriteFiles();
        _ = wf.addCopyFile(c_file, "tyio_test.c");
        const driver = wf.add("main.c",
            \\#include "tyio_test.c"
            \\int mpl_argc = 0;
            \\char **mpl_argv = 0;
            \\mpl_fin *mpl_fins = 0;
            \\int64_t mpl_nfins = 0;
            \\int64_t mpl_capfins = 0;
            \\mpl_fun *mpl_exits = 0;
            \\int64_t mpl_nexits = 0;
            \\int64_t mpl_capexits = 0;
            \\int main(int argc, char **argv) {
            \\  mpl_argc = argc;
            \\  mpl_argv = argv;
            \\  mpl_init();
            \\  return 0;
            \\}
            \\
        );
        const cc = b.addSystemCommand(&.{ "cc", "-O0", "-w", "-o" });
        const bin = cc.addOutputFileArg("tyio_test");
        cc.addFileArg(driver);

        for ([_][]const u8{ "stage1/types.mpl", "stage1/emit.mpl", "stage1/lower.mpl" }) |tyio_target| {
            const rt = std.Build.Step.Run.create(b, "run the compiled tyio_test");
            rt.addFileArg(bin);
            rt.addArg(tyio_target);
            rt.setCwd(b.path("."));
            rt.has_side_effects = true;
            rt.expectExitCode(0);
            rt.expectStdOutMatch("ok   every interned type survives a round trip\n");
            compiled_step.dependOn(&rt.step);
            test_step.dependOn(&rt.step);
        }
    }

}

const Stage0 = struct { exe: *std.Build.Step.Compile, mods: [7]*std.Build.Module };

// Stage 0's module graph and executable at one optimisation level. Built twice when the
// build is Debug: once as asked, for the installed binary and the Zig unit tests, and once
// ReleaseSafe, for the steps that run morphl (`runner`).
fn stage0(b: *std.Build, target: std.Build.ResolvedTarget,
          optimize: std.builtin.OptimizeMode) Stage0 {
    // Stage 0 front end. Dependencies run one way:
    //   diag ← keyword ← lexer ← ast ← parser ← main
    const diag = b.createModule(.{
        .root_source_file = b.path("lib/diag/diag.zig"),
        .target = target,
        .optimize = optimize,
    });

    const keyword = b.createModule(.{
        .root_source_file = b.path("lib/syntax/keyword.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lexer = b.createModule(.{
        .root_source_file = b.path("lib/lexer/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    lexer.addImport("diag", diag);
    lexer.addImport("keyword", keyword);

    const ast = b.createModule(.{
        .root_source_file = b.path("lib/ast/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    ast.addImport("diag", diag);
    ast.addImport("keyword", keyword);

    const parser = b.createModule(.{
        .root_source_file = b.path("lib/parser/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    parser.addImport("diag", diag);
    parser.addImport("keyword", keyword);
    parser.addImport("lexer", lexer);
    parser.addImport("ast", ast);

    const interp = b.createModule(.{
        .root_source_file = b.path("lib/interp/interp.zig"),
        .target = target,
        .optimize = optimize,
    });
    interp.addImport("diag", diag);
    interp.addImport("ast", ast);
    interp.addImport("lexer", lexer);
    interp.addImport("parser", parser);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("diag", diag);
    main_mod.addImport("keyword", keyword);
    main_mod.addImport("lexer", lexer);
    main_mod.addImport("ast", ast);
    main_mod.addImport("parser", parser);
    main_mod.addImport("interp", interp);

    const exe = b.addExecutable(.{
        .name = "morphlc",
        .root_module = main_mod,
    });
    return .{ .exe = exe, .mods = .{ diag, keyword, lexer, ast, parser, interp, main_mod } };
}
