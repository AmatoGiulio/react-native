/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include "PresentationPropsRegistry.h"

#include <glog/logging.h>

#include <mutex>
#include <unordered_map>

namespace facebook::react {
namespace {

std::mutex& registryMutex() {
  static std::mutex instance;
  return instance;
}

std::unordered_map<SurfaceId, PresentedPropsSnapshotMap>& registryEntries() {
  static std::unordered_map<SurfaceId, PresentedPropsSnapshotMap> instance;
  return instance;
}

bool& didLogWrite() {
  static bool value = false;
  return value;
}

bool& didLogNonEmptyRead() {
  static bool value = false;
  return value;
}

} // namespace

void PresentationPropsRegistry::update(
    SurfaceId surfaceId,
    Tag tag,
    const std::shared_ptr<const ShadowNodeFamily>& family,
    folly::dynamic props) {
  std::lock_guard lock(registryMutex());
  auto& surfaceProps = registryEntries()[surfaceId];
  auto it = surfaceProps.find(tag);
  if (it == surfaceProps.end()) {
    surfaceProps.emplace(
        tag,
        PresentedPropsSnapshot{
            .family = family,
            .props = std::move(props),
        });
  } else {
    it->second.family = family;
    it->second.props.merge_patch(props);
  }

  if (!didLogWrite()) {
    didLogWrite() = true;
    LOG(INFO) << "[PG_PATCH] write surface=" << surfaceId << " tag=" << tag;
  }
}

void PresentationPropsRegistry::remove(SurfaceId surfaceId, Tag tag) {
  std::lock_guard lock(registryMutex());
  auto surfaceIt = registryEntries().find(surfaceId);
  if (surfaceIt == registryEntries().end()) {
    return;
  }

  surfaceIt->second.erase(tag);
  if (surfaceIt->second.empty()) {
    registryEntries().erase(surfaceIt);
  }
}

PresentedPropsSnapshotMap PresentationPropsRegistry::get(SurfaceId surfaceId) {
  std::lock_guard lock(registryMutex());
  auto it = registryEntries().find(surfaceId);
  if (it == registryEntries().end()) {
    return {};
  }

  if (!it->second.empty() && !didLogNonEmptyRead()) {
    didLogNonEmptyRead() = true;
    LOG(INFO) << "[PG_PATCH] read-nonempty surface=" << surfaceId
              << " entries=" << it->second.size();
  }

  return it->second;
}

void PresentationPropsRegistry::clear(SurfaceId surfaceId) {
  std::lock_guard lock(registryMutex());
  registryEntries().erase(surfaceId);
}

} // namespace facebook::react
