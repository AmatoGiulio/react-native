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
 * Storage is defined in PresentationPropsRegistry.cpp so producers and
 * consumers always share one runtime registry instance.
 */
class PresentationPropsRegistry final {
 public:
  static void update(
      SurfaceId surfaceId,
      Tag tag,
      const std::shared_ptr<const ShadowNodeFamily>& family,
      folly::dynamic props);

  static void remove(SurfaceId surfaceId, Tag tag);

  static PresentedPropsSnapshotMap get(SurfaceId surfaceId);

  static void clear(SurfaceId surfaceId);
};

} // namespace facebook::react
