/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include "LazyShadowTreeRevisionConsistencyManager.h"

#include <glog/logging.h>
#include <react/renderer/core/ComponentDescriptor.h>
#include <react/renderer/core/PropsParserContext.h>
#include <react/renderer/core/RawProps.h>
#include <react/renderer/core/ShadowNodeFragment.h>
#include <react/renderer/uimanager/consistency/PresentationPropsRegistry.h>

#include <unordered_map>
#include <unordered_set>

namespace facebook::react {

namespace {

struct ResolvedPresentedPropsSnapshot {
  std::shared_ptr<const ShadowNodeFamily> family;
  folly::dynamic props;
};

RootShadowNode::Shared applyPresentationProps(
    const RootShadowNode::Shared& committedRoot) {
  if (committedRoot == nullptr) {
    return nullptr;
  }

  auto snapshots =
      PresentationPropsRegistry::get(committedRoot->getSurfaceId());
  if (snapshots.empty()) {
    return committedRoot;
  }

  std::unordered_set<std::shared_ptr<const ShadowNodeFamily>> families;
  std::unordered_map<Tag, ResolvedPresentedPropsSnapshot> resolvedSnapshots;
  for (const auto& [tag, snapshot] : snapshots) {
    auto family = snapshot.family.lock();
    if (family == nullptr) {
      continue;
    }

    auto ancestors = family->getAncestors(*committedRoot);
    if (!ancestors.empty()) {
      families.insert(family);
      resolvedSnapshots.emplace(
          tag,
          ResolvedPresentedPropsSnapshot{
              .family = std::move(family),
              .props = snapshot.props,
          });
    }
  }

  if (families.empty()) {
    return committedRoot;
  }

  auto presentedRoot = committedRoot->cloneMultiple(
      families,
      [&resolvedSnapshots](
          const ShadowNode& shadowNode,
          const ShadowNodeFragment& fragment) {
        auto newProps = ShadowNodeFragment::propsPlaceholder();
        auto snapshotIt = resolvedSnapshots.find(shadowNode.getTag());
        if (snapshotIt != resolvedSnapshots.end() &&
            snapshotIt->second.family == shadowNode.getFamilyShared()) {
          PropsParserContext propsParserContext{
              shadowNode.getSurfaceId(), *shadowNode.getContextContainer()};
          newProps = shadowNode.getComponentDescriptor().cloneProps(
              propsParserContext,
              shadowNode.getProps(),
              RawProps(snapshotIt->second.props));
        }

        return shadowNode.clone(
            {.props = newProps,
             .children = fragment.children,
             .state = shadowNode.getState()});
      });

  if (presentedRoot == nullptr) {
    return committedRoot;
  }

  static bool didLogPresentedRoot = false;
  if (!didLogPresentedRoot) {
    didLogPresentedRoot = true;
    LOG(INFO) << "[PG_PATCH] root-built surface="
              << committedRoot->getSurfaceId()
              << " families=" << families.size();
  }

  return std::static_pointer_cast<RootShadowNode>(presentedRoot);
}

} // namespace

LazyShadowTreeRevisionConsistencyManager::
    LazyShadowTreeRevisionConsistencyManager(
        ShadowTreeRegistry& shadowTreeRegistry)
    : shadowTreeRegistry_(shadowTreeRegistry) {}

std::shared_ptr<const RootShadowNode>
LazyShadowTreeRevisionConsistencyManager::updateCurrentRevision(
    SurfaceId surfaceId) {
  // This method is only going to be called from JS, so we don't need to protect
  // the access to the shadow tree registry as well.
  // If this was multi-threaded, we would need to protect it to avoid capturing
  // root shadow nodes concurrently.
  RootShadowNode::Shared rootShadowNode;
  shadowTreeRegistry_.visit(surfaceId, [&](const ShadowTree& shadowTree) {
    auto reactRevision = shadowTree.getCurrentReactRevision();
    rootShadowNode =
        reactRevision.value_or(shadowTree.getCurrentRevision()).rootShadowNode;
  });

  auto visibleRootShadowNode = applyPresentationProps(rootShadowNode);

  std::unique_lock lock(capturedRootShadowNodesForConsistencyMutex_);

  // We don't need to store the revision if we haven't locked.
  // We can resolve lazily when requested. When locked, capture both committed
  // state and the current presentation overlay once so all reads in the same
  // JS task observe the same revision.
  if (lockCount > 0) {
    capturedRootShadowNodesForConsistency_[surfaceId] =
        visibleRootShadowNode;
  }

  return visibleRootShadowNode;
}

#pragma mark - ShadowTreeRevisionProvider

std::shared_ptr<const RootShadowNode>
LazyShadowTreeRevisionConsistencyManager::getCurrentRevision(
    SurfaceId surfaceId) {
  {
    std::unique_lock lock(capturedRootShadowNodesForConsistencyMutex_);
    if (lockCount > 0) {
      auto it = capturedRootShadowNodesForConsistency_.find(surfaceId);
      if (it != capturedRootShadowNodesForConsistency_.end()) {
        return it->second;
      }
    }
  }

  return updateCurrentRevision(surfaceId);
}

#pragma mark - ConsistentShadowTreeRevisionProvider

void LazyShadowTreeRevisionConsistencyManager::lockRevisions() {
  std::unique_lock lock(capturedRootShadowNodesForConsistencyMutex_);

  // We actually capture the state lazily the first time we access it, so we
  // don't need to do anything here.
  lockCount++;
}

void LazyShadowTreeRevisionConsistencyManager::unlockRevisions() {
  std::unique_lock lock(capturedRootShadowNodesForConsistencyMutex_);

  if (lockCount == 0) {
    LOG(WARNING)
        << "LazyShadowTreeRevisionConsistencyManager::unlockRevisions() called without a previous lock";
  } else {
    lockCount--;
  }

  if (lockCount == 0) {
    capturedRootShadowNodesForConsistency_.clear();
  }
}

} // namespace facebook::react
