#ifndef MORPHL_ERROR_ERROR_H
#define MORPHL_ERROR_ERROR_H

#include <iostream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace morphl {
namespace error {
template <typename... Args>
std::string formatString(const std::string fmt, Args... args) {
  std::vector<std::string> argList = {
      static_cast<std::ostringstream>(std::ostringstream() << args).str()...};
  std::string result;
  size_t pos = 0, argIndex = 0;
  while (pos < fmt.size()) {
    if (fmt[pos] == '%' && argIndex < argList.size()) {
      result += argList[argIndex++];
    } else {
      result += fmt[pos];
    }
    ++pos;
  }
  return result;
}

enum class Severity : unsigned { Info = 1, Warning = 2, Critical = 3 };

class Error {
  std::string message_;
  Severity severity_;
  std::string fileName_;
  size_t row_;
  size_t col_;

public:
  template <typename... Args>
  Error(const std::string &fmt, Severity sev, Args... args)
      : message_(formatString(fmt, args...)), severity_(sev), fileName_{},
        row_{}, col_{} {}

  template <typename... Args>
  Error(const std::string &file, size_t row, size_t col, Severity sev,
        const std::string &fmt, Args... args)
      : message_(formatString(fmt, args...)), severity_(sev), fileName_(file),
        row_(row), col_(col) {}

  std::string getMessage() const { return message_; }
  Severity getSeverity() const { return severity_; }

  operator std::string() const {
    std::string pre;
    pre += fileName_;
    if (fileName_ == "") {
      pre += "<anonymous>";
    }
    if (row_ != 0) {
      pre += ":" + std::to_string(row_);
    }
    if (col_ != 0) {
      pre += ":" + std::to_string(col_) + " ";
    }
    std::string sevStr;
    switch (severity_) {
    case Severity::Info:
      sevStr = "Info";
      break;
    case Severity::Warning:
      sevStr = "Warning";
      break;
    case Severity::Critical:
      sevStr = "Critical";
      break;
    }
    return formatString("\%[\%] \%", pre, sevStr, message_);
  }
};

class ErrorManager {
  std::vector<Error> errors_;
  unsigned throwLevel_;
  unsigned showLevel_;

public:
  // default constructor of ErrorManager.
  // By default, will show severity level of warning or greater.
  // And will throw severity level of critical.
  ErrorManager() : throwLevel_(3), showLevel_(2) {}
  

  void suppressError(bool isSuppress) {
    static bool suppressFlag = false;
    static unsigned baseThrowLevel = -1;
    static unsigned baseShowLevel = -1;
    if (!isSuppress && suppressFlag || !suppressFlag && isSuppress) {
      std::swap(baseThrowLevel, this->throwLevel_);
      std::swap(baseShowLevel, this->showLevel_);
      suppressFlag = !suppressFlag;
    }
  }

  void addError(const Error err) {
    errors_.push_back(err);

    if (static_cast<unsigned>(err.getSeverity()) >= throwLevel_) {
      exit(1);
      // throwErrors();
    }
  }

  // set the show severity level
  void setShowLevel(unsigned level) { showLevel_ = level; }

  // set the throw severity level
  void setThrowLevel(unsigned level) { throwLevel_ = level; }

  void reportErrors() const {
    bool found = false;
    int warningCount = 0, criticalCount = 0;
    for (const auto &err : errors_) {
      if (static_cast<unsigned>(err.getSeverity()) >= showLevel_) {
        found = true;
        if (err.getSeverity() == Severity::Warning) {
          ++warningCount;
        } else if (err.getSeverity() == Severity::Critical) {
          ++criticalCount;
        }
      }
    }

    // no matching error are found
    if (!found) {
      std::cerr << "No errors reported.\n";
      return;
    }

    std::cerr << "Error Report: ";
    if (showLevel_ <= 2 && warningCount > 0) {
      std::cerr << formatString("(\% Criticals, \% Warnings)\n", criticalCount,
                                warningCount);
    } else {
      std::cerr << formatString("(\% Criticals)\n", criticalCount);
    }

    for (const auto &err : errors_) {
      if (static_cast<unsigned>(err.getSeverity()) >= showLevel_) {
        std::cerr << static_cast<std::string>(err);
      }
    }
    exit(1);
  }

  void throwErrors() const {
    bool found = false;
    for (const auto &err : errors_) {
      if (static_cast<unsigned>(err.getSeverity()) >= throwLevel_) {
        found = true;
        break;
      }
    }
    if (found) {
      reportErrors();
      exit(1);
    }
  }

  ~ErrorManager() {
    reportErrors();
    throwErrors();
  }
};

extern ErrorManager errorManager;

} // namespace error
} // namespace morphl

#endif // !MORPHL_ERROR_ERROR_H
