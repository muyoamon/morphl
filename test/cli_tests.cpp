#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <fstream>
#include <sstream>
#include <string>

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static std::string make_temp_dir() {
  char templ[] = "/tmp/morphl_cli_test_XXXXXX";
  char* path = mkdtemp(templ);
  assert(path != NULL);
  return std::string(path);
}

static bool file_exists(const std::string& path) {
  struct stat st;
  return stat(path.c_str(), &st) == 0;
}

static std::string read_file(const std::string& path) {
  std::ifstream in(path);
  std::stringstream buffer;
  buffer << in.rdbuf();
  return buffer.str();
}

static std::string write_file(const std::string& path, const std::string& content) {
  std::ofstream out(path, std::ios::trunc);
  assert(out.is_open());
  out << content;
  out.close();
  return path;
}

static int run_command_capture(const std::string& command,
                               const std::string& output_path) {
  std::string shell_command = command + " >" + output_path + " 2>&1";
  int status = std::system(shell_command.c_str());
  assert(status != -1);
  assert(WIFEXITED(status));
  return WEXITSTATUS(status);
}

static std::string quote_arg(const std::string& value) {
  return "'" + value + "'";
}

static void test_default_vm_output() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/default.log";
  std::string output_path = temp_dir + "/out.mplx";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " " + quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(output_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to out.mplx") != std::string::npos);
  assert(output.find("executing VM bytecode from out.mplx") != std::string::npos);
}

static void test_compile_only_vm_output() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/compile_only.log";
  std::string output_path = temp_dir + "/out.mplo";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -c " + quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(output_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to out.mplo") != std::string::npos);
  assert(output.find("executing VM bytecode from") == std::string::npos);
}

static void test_custom_c_output() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/custom_c.log";
  std::string output_path = temp_dir + "/custom_output.c";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " --backend c -o " +
                        quote_arg(output_path) + " " + quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(output_path));

  std::string output = read_file(log_path);
  assert(output.find(output_path) != std::string::npos);
}

static void test_custom_vm_output_runs() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/custom_vm.log";
  std::string output_path = temp_dir + "/custom_output.mplx";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -o " +
                        quote_arg(output_path) + " " + quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(output_path));

  std::string output = read_file(log_path);
  assert(output.find("executing VM bytecode from " + output_path) != std::string::npos);
}

static void test_vm_compile_links_import_graph() {
  std::string temp_dir = make_temp_dir();
  std::string dep_path = temp_dir + "/dep.mpl";
  std::string root_path = temp_dir + "/root.mpl";
  std::string exe_path = temp_dir + "/linked.mplx";
  std::string log_path = temp_dir + "/linked.log";

  write_file(dep_path,
             "$decl dep_func $func () {\n"
             "  $ret 9;\n"
             "};\n");
  write_file(root_path,
             std::string("$decl dep $import \"") + dep_path + "\";\n" +
                 "$exit $call $member dep dep_func ();\n");

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -o " +
                        quote_arg(exe_path) + " " + quote_arg(root_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 9);
  assert(file_exists(exe_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to " + exe_path) != std::string::npos);
  assert(output.find("executing VM bytecode from " + exe_path) != std::string::npos);
}

static void test_vm_compile_runs_imported_recursive_function() {
  std::string temp_dir = make_temp_dir();
  std::string dep_path = temp_dir + "/factorial.mpl";
  std::string root_path = temp_dir + "/root.mpl";
  std::string exe_path = temp_dir + "/factorial.mplx";
  std::string log_path = temp_dir + "/factorial.log";
  std::string grammar_path =
      std::string(MORPHL_SOURCE_DIR) + "/examples/grammar_sample.txt";

  write_file(dep_path,
             std::string("$syntax \"") + grammar_path + "\";\n" +
             "fact := (n := 0) => {\n"
             "  if (n <= 1) {\n"
             "    return 1;\n"
             "  } else {\n"
             "    return n * fact(n - 1);\n"
             "  };\n"
             "};\n");
  write_file(root_path,
             std::string("$decl fact $import \"") + dep_path + "\";\n" +
                 "$exit $call $member fact fact 5;\n");

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -o " +
                        quote_arg(exe_path) + " " + quote_arg(root_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 120);
  assert(file_exists(exe_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to " + exe_path) != std::string::npos);
  assert(output.find("executing VM bytecode from " + exe_path) != std::string::npos);
}

static void test_vm_compile_ignores_type_only_import_dependency() {
  std::string temp_dir = make_temp_dir();
  std::string iterable_path = temp_dir + "/iterable.mpl";
  std::string array_path = temp_dir + "/array.mpl";
  std::string exe_path = temp_dir + "/array.mplx";
  std::string log_path = temp_dir + "/array.log";

  write_file(iterable_path,
             "$decl Iterable $template T $traits {\n"
             "  $prop foreach $func ($decl cb $func T ()) ();\n"
             "};\n");
  write_file(array_path,
             std::string("$alias Iterable $member $import \"") +
                 iterable_path + "\" Iterable;\n"
             "$decl Array $template (T, L) $impl $specialize Iterable T {\n"
             "  $decl val $array T L;\n"
             "  $decl length $add L 0;\n"
             "} {\n"
             "  $prop foreach $func ($decl cb $func T ()) {\n"
             "    $ret ();\n"
             "  };\n"
             "};\n");

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -o " +
                        quote_arg(exe_path) + " " + quote_arg(array_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(exe_path));

  std::string output = read_file(log_path);
  assert(output.find("unrelated object") == std::string::npos);
  assert(output.find("output written to " + exe_path) != std::string::npos);
}

static void test_std_iterable_compiles() {
  std::string temp_dir = make_temp_dir();
  std::string object_path = temp_dir + "/iterable.mplo";
  std::string log_path = temp_dir + "/iterable.log";
  std::string iterable_path = std::string(MORPHL_SOURCE_DIR) + "/std/iterable.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -c -o " +
                        quote_arg(object_path) + " " + quote_arg(iterable_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(object_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to " + object_path) != std::string::npos);
  assert(output.find("group\n"
                     "                      ident T\n"
                     "                      literal 0") != std::string::npos);
}

static void test_std_iterable_import_exports_templates() {
  std::string temp_dir = make_temp_dir();
  std::string source_path = temp_dir + "/use_iterable.mpl";
  std::string object_path = temp_dir + "/use_iterable.mplo";
  std::string log_path = temp_dir + "/use_iterable.log";
  std::string iterable_path = std::string(MORPHL_SOURCE_DIR) + "/std/iterable.mpl";

  write_file(source_path,
             std::string("$alias Iterator $member $import \"") +
                 iterable_path + "\" Iterator;\n"
             "$alias Iterable $member $import \"" +
                 iterable_path + "\" Iterable;\n");

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -c -o " +
                        quote_arg(object_path) + " " + quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(object_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to " + object_path) != std::string::npos);
}

static void test_mplvm_runs_executable() {
  std::string temp_dir = make_temp_dir();
  std::string source_path = temp_dir + "/prog.mpl";
  std::string exe_path = temp_dir + "/prog.mplx";
  std::string compile_log = temp_dir + "/compile.log";
  std::string run_log = temp_dir + "/run.log";

  write_file(source_path, "$exit 7;\n");

  std::string compile_command =
      "cd " + quote_arg(temp_dir) + " && " + quote_arg(MORPHLC_PATH) +
      " -o " + quote_arg(exe_path) + " " + quote_arg(source_path);
  int compile_exit = run_command_capture(compile_command, compile_log);
  assert(compile_exit == 7);
  assert(file_exists(exe_path));

  std::string run_command =
      quote_arg(MPLVM_PATH) + " " + quote_arg(exe_path);
  int run_exit = run_command_capture(run_command, run_log);
  assert(run_exit == 7);
}

static void test_mplinsp_reads_object_file() {
  std::string temp_dir = make_temp_dir();
  std::string source_path = temp_dir + "/prog.mpl";
  std::string object_path = temp_dir + "/prog.mplo";
  std::string compile_log = temp_dir + "/compile.log";
  std::string insp_log = temp_dir + "/insp.log";

  write_file(source_path, "$decl value 1;\n");

  std::string compile_command =
      "cd " + quote_arg(temp_dir) + " && " + quote_arg(MORPHLC_PATH) +
      " -c -o " + quote_arg(object_path) + " " + quote_arg(source_path);
  int compile_exit = run_command_capture(compile_command, compile_log);
  assert(compile_exit == 0);
  assert(file_exists(object_path));

  std::string insp_command =
      quote_arg(MPLINSP_PATH) + " " + quote_arg(object_path);
  int insp_exit = run_command_capture(insp_command, insp_log);
  assert(insp_exit == 0);

  std::string output = read_file(insp_log);
  assert(output.find("Artifact:      object") != std::string::npos);
}

static void test_mplinsp_reads_executable_file() {
  std::string temp_dir = make_temp_dir();
  std::string source_path = temp_dir + "/prog.mpl";
  std::string exe_path = temp_dir + "/prog.mplx";
  std::string compile_log = temp_dir + "/compile.log";
  std::string insp_log = temp_dir + "/insp.log";

  write_file(source_path, "$exit 3;\n");

  std::string compile_command =
      "cd " + quote_arg(temp_dir) + " && " + quote_arg(MORPHLC_PATH) +
      " -o " + quote_arg(exe_path) + " " + quote_arg(source_path);
  int compile_exit = run_command_capture(compile_command, compile_log);
  assert(compile_exit == 3);
  assert(file_exists(exe_path));

  std::string insp_command =
      quote_arg(MPLINSP_PATH) + " " + quote_arg(exe_path);
  int insp_exit = run_command_capture(insp_command, insp_log);
  assert(insp_exit == 0);

  std::string output = read_file(insp_log);
  assert(output.find("Artifact:      executable") != std::string::npos);
}

static void test_mplvm_rejects_object_file() {
  std::string temp_dir = make_temp_dir();
  std::string source_path = temp_dir + "/prog.mpl";
  std::string object_path = temp_dir + "/prog.mplo";
  std::string compile_log = temp_dir + "/compile.log";
  std::string run_log = temp_dir + "/run.log";

  write_file(source_path, "$decl value 1;\n");

  std::string compile_command =
      "cd " + quote_arg(temp_dir) + " && " + quote_arg(MORPHLC_PATH) +
      " -c -o " + quote_arg(object_path) + " " + quote_arg(source_path);
  int compile_exit = run_command_capture(compile_command, compile_log);
  assert(compile_exit == 0);
  assert(file_exists(object_path));

  std::string run_command =
      quote_arg(MPLVM_PATH) + " " + quote_arg(object_path);
  int run_exit = run_command_capture(run_command, run_log);
  assert(run_exit != 0);

  std::string output = read_file(run_log);
  assert(output.find("not a runnable VM executable") != std::string::npos);
}

static void test_mpll_links_objects_and_mplinsp_reads_executable() {
  std::string temp_dir = make_temp_dir();
  std::string dep_path = temp_dir + "/dep.mpl";
  std::string root_path = temp_dir + "/root.mpl";
  std::string dep_obj = temp_dir + "/dep.mplo";
  std::string root_obj = temp_dir + "/root.mplo";
  std::string exe_path = temp_dir + "/linked.mplx";
  std::string dep_log = temp_dir + "/dep.log";
  std::string root_log = temp_dir + "/root.log";
  std::string link_log = temp_dir + "/link.log";
  std::string insp_log = temp_dir + "/insp.log";

  write_file(dep_path,
             "$decl dep_func $func () {\n"
             "  $ret 11;\n"
             "};\n");
  write_file(root_path,
             std::string("$decl dep $import \"") + dep_path + "\";\n" +
                 "$exit $call $member dep dep_func ();\n");

  int dep_exit = run_command_capture(
      "cd " + quote_arg(temp_dir) + " && " + quote_arg(MORPHLC_PATH) +
      " -c -o " + quote_arg(dep_obj) + " " + quote_arg(dep_path),
      dep_log);
  int root_exit = run_command_capture(
      "cd " + quote_arg(temp_dir) + " && " + quote_arg(MORPHLC_PATH) +
      " -c -o " + quote_arg(root_obj) + " " + quote_arg(root_path),
      root_log);
  assert(dep_exit == 0);
  assert(root_exit == 0);
  assert(file_exists(dep_obj));
  assert(file_exists(root_obj));

  int link_exit = run_command_capture(
      quote_arg(MPLL_PATH) + " " + quote_arg(exe_path) + " " +
      quote_arg(root_obj) + " " + quote_arg(dep_obj),
      link_log);
  assert(link_exit == 0);
  assert(file_exists(exe_path));

  int insp_exit = run_command_capture(
      quote_arg(MPLINSP_PATH) + " " + quote_arg(exe_path),
      insp_log);
  assert(insp_exit == 0);

  std::string output = read_file(insp_log);
  assert(output.find("Artifact:      executable") != std::string::npos);
}

static void test_mpll_rejects_executable_input() {
  std::string temp_dir = make_temp_dir();
  std::string source_path = temp_dir + "/prog.mpl";
  std::string exe_input = temp_dir + "/prog.mplx";
  std::string exe_output = temp_dir + "/linked.mplx";
  std::string compile_log = temp_dir + "/compile.log";
  std::string link_log = temp_dir + "/link.log";

  write_file(source_path, "$exit 0;\n");

  int compile_exit = run_command_capture(
      "cd " + quote_arg(temp_dir) + " && " + quote_arg(MORPHLC_PATH) +
      " -o " + quote_arg(exe_input) + " " + quote_arg(source_path),
      compile_log);
  assert(compile_exit == 0);
  assert(file_exists(exe_input));

  int link_exit = run_command_capture(
      quote_arg(MPLL_PATH) + " " + quote_arg(exe_output) + " " +
      quote_arg(exe_input),
      link_log);
  assert(link_exit != 0);

  std::string output = read_file(link_log);
  assert(output.find("is not a VM object file") != std::string::npos);
}

static void test_c_backend_is_compile_only() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/c_backend.log";
  std::string output_path = temp_dir + "/out.c";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " --backend c " +
                        quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(output_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to out.c") != std::string::npos);
  assert(output.find("executing VM bytecode from") == std::string::npos);
}

static void test_missing_output_filename() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/missing_output.log";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -o";
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code != 0);

  std::string output = read_file(log_path);
  assert(output.find("missing output filename after -o") != std::string::npos);
}

static void test_run_flag_removed() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/run_flag.log";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " --run " +
                        quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code != 0);

  std::string output = read_file(log_path);
  assert(output.find("unknown option '--run'") != std::string::npos);
}

int main() {
  test_default_vm_output();
  test_compile_only_vm_output();
  test_custom_c_output();
  test_custom_vm_output_runs();
  test_vm_compile_links_import_graph();
  test_vm_compile_runs_imported_recursive_function();
  test_vm_compile_ignores_type_only_import_dependency();
  test_std_iterable_compiles();
  test_std_iterable_import_exports_templates();
  test_mplvm_runs_executable();
  test_mplinsp_reads_object_file();
  test_mplinsp_reads_executable_file();
  test_mplvm_rejects_object_file();
  test_mpll_links_objects_and_mplinsp_reads_executable();
  test_mpll_rejects_executable_input();
  test_c_backend_is_compile_only();
  test_missing_output_filename();
  test_run_flag_removed();
  printf("PASS cli_tests\n");
  return 0;
}
