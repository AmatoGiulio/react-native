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
 * Stores geometry-affecting props that have already been presented directly
 * on native views without producing a committed ShadowTree revision.
 *
 * Readers always receive an immutable copy so a single geometry query observes
 * one presentation snapshot even while an animation continues on another
 * thread.
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
