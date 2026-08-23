/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include "AnimationBackend.h"
#include "AnimatedPropsRegistry.h"

#include <react/debug/react_native_assert.h>
#include <react/featureflags/ReactNativeFeatureFlags.h>
#include <react/renderer/animationbackend/AnimatedPropsSerializer.h>
#include <react/renderer/core/PresentationPropsRegistry.h>
#include <react/renderer/graphics/Color.h>
#include <chrono>
#include <utility>

namespace facebook::react {

static inline Props::Shared cloneProps(
    AnimatedProps& animatedProps,
    const ShadowNode& shadowNode) {
  PropsParserContext propsParserContext{
      shadowNode.getSurfaceId(), *shadowNode.getContextContainer()};
  Props::Shared newProps;
  if (animatedProps.rawProps) {
    if (ReactNativeFeatureFlags::enableFabricCommitBranching()) {
      newProps = shadowNode.getComponentDescriptor().cloneProps(
          propsParserContext,
          shadowNode.getProps(),
          std::move(*animatedProps.rawProps));
    } else {
      newProps = shadowNode.getComponentDescriptor().cloneProps(
          propsParserContext,
          shadowNode.getProps(),
          RawProps(*animatedProps.rawProps));
    }
  } else {
    newProps = shadowNode.getComponentDescriptor().cloneProps(
        propsParserContext, shadowNode.getProps(), {});
  }

  auto viewProps = std::const_pointer_cast<BaseViewProps>(
      std::static_pointer_cast<const BaseViewProps>(newProps));
  for (auto& animatedProp : animatedProps.props) {
    cloneProp(*viewProps, *animatedProp);
  }
  return newProps;
}

AnimationBackend::AnimationBackend(
    std::shared_ptr<AnimationChoreographer> animationChoreographer,
    std::shared_ptr<UIManager> uiManager)
    : animatedPropsRegistry_(std::make_shared<AnimatedPropsRegistry>()),
      animationChoreographer_(std::move(animationChoreographer)),
      commitHook_(*uiManager, animatedPropsRegistry_),
      uiManager_(std::move(uiManager)) {
  react_native_assert(uiManager_.expired() == false);

  auto weakAnimatedPropsRegistry =
      std::weak_ptr<AnimatedPropsRegistry>(animatedPropsRegistry_);
  auto initializeSurfaceContext =
      [weakAnimatedPropsRegistry](const ShadowTree& shadowTree) {
        if (auto animatedPropsRegistry = weakAnimatedPropsRegistry.lock()) {
          animatedPropsRegistry->initializeSurface(shadowTree.getSurfaceId());
        }
      };

  if (auto lockedUIManager = uiManager_.lock()) {
    lockedUIManager->addOnSurfaceStartCallback(initializeSurfaceContext);
    lockedUIManager->getShadowTreeRegistry().enumerate(
        [&](const ShadowTree& shadowTree, bool& /*stop*/) {
          animatedPropsRegistry_->initializeSurface(shadowTree.getSurfaceId());
        });
  }
}

void AnimationBackend::unpackMutations(
    AnimationMutations& mutations,
    std::unordered_map<SurfaceId, SurfaceUpdates>& surfaceUpdates,
    std::set<SurfaceId>& asyncFlushSurfaces) {
  for (auto& mutation : mutations.batch) {
    const auto family = mutation.family;
    react_native_assert(family != nullptr);

    auto& [families, updates, hasLayoutUpdates] =
        surfaceUpdates[family->getSurfaceId()];
    hasLayoutUpdates |= mutation.hasLayoutUpdates;
    families.insert(family);
    updates[mutation.tag] = std::move(mutation.props);
  }

  asyncFlushSurfaces.merge(mutations.asyncFlushSurfaces);
}

void AnimationBackend::applySurfaceUpdates(
    std::unordered_map<SurfaceId, SurfaceUpdates>& surfaceUpdates,
    const std::set<SurfaceId>& asyncFlushSurfaces) {
  animatedPropsRegistry_->update(surfaceUpdates);

  for (auto& [surfaceId, updates] : surfaceUpdates) {
    if (updates.hasLayoutUpdates) {
      commitUpdates(surfaceId, updates);
    } else {
      synchronouslyUpdateProps(
          surfaceId, updates.propsMap, updates.families);
    }
  }

  requestAsyncFlushForSurfaces(asyncFlushSurfaces);
}

void AnimationBackend::applyMutations(AnimationMutations mutations) {
  std::unordered_map<SurfaceId, SurfaceUpdates> surfaceUpdates;
  std::set<SurfaceId> asyncFlushSurfaces;
  unpackMutations(mutations, surfaceUpdates, asyncFlushSurfaces);
  applySurfaceUpdates(surfaceUpdates, asyncFlushSurfaces);
}

void AnimationBackend::onAnimationFrame(AnimationTimestamp timestamp) {
  std::vector<CallbackWithId> callbacksCopy;

  {
    std::lock_guard lock(mutex_);
    callbacksCopy = callbacks;
  }

  std::unordered_map<SurfaceId, SurfaceUpdates> surfaceUpdates;
  std::set<SurfaceId> asyncFlushSurfaces;
  for (auto& callbackWithId : callbacksCopy) {
    auto mutations = callbackWithId.callback(timestamp);
    unpackMutations(mutations, surfaceUpdates, asyncFlushSurfaces);
  }
  applySurfaceUpdates(surfaceUpdates, asyncFlushSurfaces);
}

CallbackId AnimationBackend::start(const Callback& callback) {
  std::lock_guard lock(mutex_);

  auto callbackId = nextCallbackId_++;
  callbacks.push_back({.callbackId = callbackId, .callback = callback});
  if (!isRenderCallbackStarted_) {
    animationChoreographer_->resume();
    isRenderCallbackStarted_ = true;
  }

  return callbackId;
}

void AnimationBackend::stop(CallbackId callbackId) {
  std::lock_guard lock(mutex_);

  auto it = std::find_if(callbacks.begin(), callbacks.end(), [&](auto& c) {
    return c.callbackId == callbackId;
  });
  if (it == callbacks.end()) {
    return;
  }

  callbacks.erase(it);
  if (isRenderCallbackStarted_ && callbacks.empty()) {
    animationChoreographer_->pause();
    isRenderCallbackStarted_ = false;
  }
}

void AnimationBackend::trigger() {
  onAnimationFrame(std::chrono::steady_clock::now().time_since_epoch());
}

void AnimationBackend::pushAnimationMutations(const Callback& callback) {
  auto timestamp = animationChoreographer_->now();
  auto mutations = callback(timestamp);
  applyMutations(std::move(mutations));
}

void AnimationBackend::commitUpdates(
    SurfaceId surfaceId,
    SurfaceUpdates& surfaceUpdates) {
  auto uiManager = uiManager_.lock();
  if (!uiManager) {
    return;
  }

  auto& surfaceFamilies = surfaceUpdates.families;
  auto& updates = surfaceUpdates.propsMap;

  uiManager->getShadowTreeRegistry().visit(
      surfaceId, [&surfaceFamilies, &updates](const ShadowTree& shadowTree) {
        shadowTree.commit(
            [&surfaceFamilies,
             &updates](const RootShadowNode& oldRootShadowNode) {
              return std::static_pointer_cast<RootShadowNode>(
                  oldRootShadowNode.cloneMultiple(
                      surfaceFamilies,
                      [&surfaceFamilies, &updates](
                          const ShadowNode& shadowNode,
                          const ShadowNodeFragment& fragment) {
                        auto newProps = ShadowNodeFragment::propsPlaceholder();
                        if (surfaceFamilies.contains(
                                shadowNode.getFamilyShared())) {
                          auto& animatedProps = updates.at(shadowNode.getTag());
                          newProps = cloneProps(animatedProps, shadowNode);
                        }
                        return shadowNode.clone(
                            {.props = newProps,
                             .children = fragment.children,
                             .state = shadowNode.getState()});
                      }));
            },
            {.mountSynchronously = true});
      });
}

void AnimationBackend::synchronouslyUpdateProps(
    SurfaceId surfaceId,
    const std::unordered_map<Tag, AnimatedProps>& updates,
    const std::unordered_set<std::shared_ptr<const ShadowNodeFamily>>&
        families) {
  for (auto& [tag, animatedProps] : updates) {
    auto dyn = animationbackend::packAnimatedProps(animatedProps);
    if (auto uiManager = uiManager_.lock()) {
      uiManager->synchronouslyUpdateViewOnUIThread(tag, dyn);

      auto familyIt = std::find_if(
          families.begin(), families.end(), [tag](const auto& family) {
            return family != nullptr && family->getTag() == tag;
          });
      if (familyIt == families.end()) {
        continue;
      }

      // An empty direct update is how Native Animated restores defaults when a
      // props node disconnects. Drop any presentation override for the tag so
      // subsequent geometry reads fall back to the committed props.
      if (dyn.empty()) {
        PresentationPropsRegistry::remove(surfaceId, tag);
        continue;
      }

      folly::dynamic geometryProps = folly::dynamic::object();
      if (dyn.count("transform") != 0u) {
        geometryProps["transform"] = dyn["transform"];
      }
      if (dyn.count("transformOrigin") != 0u) {
        geometryProps["transformOrigin"] = dyn["transformOrigin"];
      }
      if (geometryProps.empty()) {
        continue;
      }

      PresentationPropsRegistry::update(
          surfaceId, tag, *familyIt, std::move(geometryProps));
    }
  }
}

void AnimationBackend::requestAsyncFlushForSurfaces(
    const std::set<SurfaceId>& surfaces) {
  react_native_assert(
      jsInvoker_ != nullptr ||
      surfaces.empty() && "jsInvoker_ was not provided");
  std::weak_ptr<AnimatedPropsRegistry> weakAnimatedPropsRegistry =
      animatedPropsRegistry_;
  for (const auto& surfaceId : surfaces) {
    jsInvoker_->invokeAsync(
        [weakUIManager = uiManager_, surfaceId, weakAnimatedPropsRegistry]() {
          auto uiManager = weakUIManager.lock();
          if (!uiManager) {
            return;
          }
          uiManager->getShadowTreeRegistry().visit(
              surfaceId,
              [weakAnimatedPropsRegistry](const ShadowTree& shadowTree) {
                auto result = shadowTree.commit(
                    [weakAnimatedPropsRegistry](
                        const RootShadowNode& oldRootShadowNode) {
                      return std::static_pointer_cast<RootShadowNode>(
                          oldRootShadowNode.ShadowNode::clone({}));
                    },
                    {.source = ShadowTreeCommitSource::AnimationEndSync});
                if (result == ShadowTree::CommitStatus::Succeeded &&
                    ReactNativeFeatureFlags::
                        updateRuntimeShadowNodeReferencesOnCommitThread()) {
                  if (auto animatedPropsRegistry =
                          weakAnimatedPropsRegistry.lock()) {
                    animatedPropsRegistry->clear(shadowTree.getSurfaceId());
                  }
                }
              });
        });
  }
}

void AnimationBackend::clearRegistry(SurfaceId surfaceId) {
  animatedPropsRegistry_->clear(surfaceId);
  PresentationPropsRegistry::clear(surfaceId);
}

void AnimationBackend::clearRegistryOnSurfaceStop(SurfaceId surfaceId) {
  animatedPropsRegistry_->clearOnSurfaceStop(surfaceId);
  PresentationPropsRegistry::clear(surfaceId);
}

void AnimationBackend::registerJSInvoker(
    std::shared_ptr<CallInvoker> jsInvoker) {
  if (!jsInvoker_) {
    jsInvoker_ = jsInvoker;
  }
}

} // namespace facebook::react
