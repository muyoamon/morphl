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
  std::string output_path = temp_dir + "/out.mbc";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " " + quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(output_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to out.mbc") != std::string::npos);
  assert(output.find("executing VM bytecode from out.mbc") != std::string::npos);
}

static void test_compile_only_vm_output() {
  std::string temp_dir = make_temp_dir();
  std::string log_path = temp_dir + "/compile_only.log";
  std::string output_path = temp_dir + "/out.mbc";
  std::string source_path = std::string(MORPHL_SOURCE_DIR) + "/examples/minimal.mpl";

  std::string command = "cd " + quote_arg(temp_dir) + " && " +
                        quote_arg(MORPHLC_PATH) + " -c " + quote_arg(source_path);
  int exit_code = run_command_capture(command, log_path);

  assert(exit_code == 0);
  assert(file_exists(output_path));

  std::string output = read_file(log_path);
  assert(output.find("output written to out.mbc") != std::string::npos);
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
  std::string output_path = temp_dir + "/custom_output.mbc";
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
  test_c_backend_is_compile_only();
  test_missing_output_filename();
  test_run_flag_removed();
  printf("PASS cli_tests\n");
  return 0;
}
