#include "config.h"
#include <string>
#define S(str, f, v) {str, [](Config& c){c.f = v;}}
namespace morphl {
namespace config {
  Config gConfig{};

  
  typedef std::function<void(Config&)> NoArgHandle;
  static const std::unordered_map<std::string, NoArgHandle> NoArgs{
    S("--help", help, true),
    S("-h", help, true),
    S("-v", verbose, true),
    S("--verbose", verbose, true),
    S("-q", verbose, false),
    S("--quiet", verbose, false)
  };

  void readConfig(Config &c, int argc, const char *argv[]) {
    if (argc == 0) return;
    for (int i = 1; i < argc; i++) {
      std::string opt{argv[i]};
      if (auto j{NoArgs.find(opt)}; j != NoArgs.end()) {
        j->second(gConfig);
      } else if (c.inFile == "") {
        c.inFile = opt;
      }
    }
  }
};
}

