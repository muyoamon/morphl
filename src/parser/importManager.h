#ifndef MORPHL_IMPORTMANAGER_H
#define MORPHL_IMPORTMANAGER_H

#include <filesystem>
#include <memory>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "../ast/ast.h"
#include "../type/type.h"
namespace morphl {
namespace parser {
class ImportManager {
  using ImportKeyT = std::filesystem::path;
  using ImportValT = std::unique_ptr<AST::ASTNode>;
  using Import = std::pair<ImportKeyT, ImportValT>;
  using ImportContainer = std::unordered_map<ImportKeyT, ImportValT>;

  static ImportContainer imports_;
  static std::unordered_set<ImportKeyT> importsTracker_; 
  public: 
  static ImportValT getNode(const std::filesystem::path);
  static std::shared_ptr<type::TypeObject> addImport(const ImportKeyT,
                                                     ImportValT &&);
  static std::shared_ptr<type::TypeObject> getType(const ImportKeyT);
  static void addTracker(const ImportKeyT);
  static bool findTracker(const ImportKeyT);
  static void removeTracker(const ImportKeyT);
};
} // namespace parser
} // namespace morphl

#endif // MORPHL_IMPORTMANAGER_H
