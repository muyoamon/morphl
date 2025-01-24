#include "importManager.h"
#include <cstdio>
#include <filesystem>
#include <memory>
#include <unordered_set>

namespace morphl {
ImportManager::ImportContainer ImportManager::imports_{};
std::unordered_set<ImportManager::ImportKeyT> ImportManager::importsTracker_{};
ImportManager::ImportValT
ImportManager::getNode(const std::filesystem::path path) {
  return imports_[path]->clone();
}
std::shared_ptr<type::TypeObject>
ImportManager::getType(const ImportManager::ImportKeyT path) {
  if (imports_[path] == nullptr) {
    return nullptr;
  }
  return imports_[path]->getType();
}
std::shared_ptr<type::TypeObject>
ImportManager::addImport(const ImportManager::ImportKeyT path,
                         ImportManager::ImportValT &&node) {
   if (findTracker(path)) {
    return nullptr;
  }
  addTracker(path);
  if (imports_[path] == nullptr) {
    imports_[path] = std::move(node);
  }
  removeTracker(path);
  return getType(path);
}
void ImportManager::addTracker(const ImportManager::ImportKeyT path) {
  importsTracker_.insert(path);
}
bool ImportManager::findTracker(const ImportManager::ImportKeyT path) {
  if (importsTracker_.find(path) != importsTracker_.end()) {
    return true;
  }
  return false;
}

void ImportManager::removeTracker(const ImportManager::ImportKeyT path) {
  importsTracker_.erase(path);
}
} // namespace morphl
