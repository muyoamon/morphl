#ifndef MORPHL_CONFIG_CONFIG_H
#define MORPHL_CONFIG_CONFIG_H

#include <functional>
#include <string>
#include <unordered_map>
namespace morphl {
namespace config {
  struct Config {
    bool verbose{false};
    bool help{false};
    std::string inFile;

  };

  void readConfig(Config& c, int argc, const char * argv[]);

  extern Config gConfig;
}
}

#endif  // MORPHL_CONFIG_CONFIG_H
