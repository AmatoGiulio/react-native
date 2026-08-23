/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#pragma once

#include <folly/dynamic.h>
#include <react/renderer/core/ReactPrimitives.h>
#include <react/renderer/core/ShadowNodeFamily.h>

#include <memory>
#include <mutex>
#include <unordered_map>

namespace facebook::react {

struct PresentedPropsSnapshot {
  std::weak_ptr<const ShadowNodeFamily> family;
  folly::dynamic props;
};

using PresentedPropsSnapshotMap =
    std::unordered_map<Tag, PresentedPropsSnapshot>;

/**
 * Experimental proof-only registry for props that have already been applied
 * directly to native views without producing a new committed ShadowTree
 * revision.
 *
 * The registry deliberately tracks presentation state separately from the
 * AnimationBackend reconciliation registry. Geometry readers may use a copy of
 * this state to build an ephemeral ShadowTree revision; it must never be
 * mounted or propagated through RSNRU.
 */
class PresentationPropsRegistry final {
 public:
  static void update(
      SurfaceId surfaceId,
      Tag tag,
      const std::shared_ptr<const ShadowNodeFamily>& family,
      folly::dynamic props) {
    std::lock_guard lock(mutex());
    auto& surfaceProps = entries()[surfaceId];
    auto it = surfaceProps.find(tag);
    if (it == surfaceProps.end()) {
      surfaceProps.emplace(
          tag,
          PresentedPropsSnapshot{
              .family = family,
              .props = std::move(props),
          });
      return;
    }

    it->second.family = family;
    it->second.props.merge_patch(props);
  }

  static void remove(SurfaceId surfaceId, Tag tag) {
    std::lock_guard lock(mutex());
    auto surfaceIt = entries().find(surfaceId);
    if (surfaceIt == entries().end()) {
      return;
    }

    surfaceIt->second.erase(tag);
    if (surfaceIt->second.empty()) {
      entries().erase(surfaceIt);
    }
  }

  static PresentedPropsSnapshotMap get(SurfaceId surfaceId) {
    std::lock_guard lock(mutex());
    auto it = entries().find(surfaceId);
    return it == entries().end() ? PresentedPropsSnapshotMap{} : it->second;
  }

  static void clear(SurfaceId surfaceId) {
    std::lock_guard lock(mutex());
    entries().erase(surfaceId);
  }

 private:
  static std::mutex& mutex() {
    static std::mutex instance;
    return instance;
  }

  static std::unordered_map<SurfaceId, PresentedPropsSnapshotMap>& entries() {
    static std::unordered_map<SurfaceId, PresentedPropsSnapshotMap> instance;
    return instance;
  }
};

} // namespace facebook::react
