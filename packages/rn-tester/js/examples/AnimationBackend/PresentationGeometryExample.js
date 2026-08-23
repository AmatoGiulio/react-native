/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @flow strict-local
 * @format
 */

import type {RNTesterModuleExample} from '../../types/RNTesterTypes';

import * as React from 'react';
import {
  Alert,
  Animated,
  Easing,
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

const SAMPLE_INTERVAL_MS = 50;
const SAMPLES_PER_RUN = 800;
const RUN_COUNT = 3;
const RUN_GAP_MS = 300;
const FREEZE_EPSILON_PX = 0.25;
const FREEZE_THRESHOLD_MS = 120;
const WARMUP_MS = 600;

type RunResult = {
  run: number,
  minPageY: number,
  maxPageY: number,
  span: number,
  samples: number,
  freezeEpisodes: number,
  maxFreezeMs: number,
  durationMs: number,
};

function PresentationGeometryExample(): React.Node {
  const translateY = React.useRef(new Animated.Value(0)).current;
  const measuredViewRef = React.useRef<React.ElementRef<typeof View> | null>(
    null,
  );
  const runningRef = React.useRef(false);
  const mountedRef = React.useRef(true);
  const pressInCountRef = React.useRef(0);
  const pressCountRef = React.useRef(0);
  const animationRef = React.useRef<?{stop: () => void}>(null);
  const intervalRef = React.useRef<?IntervalID>(null);
  const nextRunTimeoutRef = React.useRef<?TimeoutID>(null);

  React.useEffect(() => {
    return () => {
      mountedRef.current = false;
      animationRef.current?.stop();
      if (intervalRef.current != null) {
        clearInterval(intervalRef.current);
      }
      if (nextRunTimeoutRef.current != null) {
        clearTimeout(nextRunTimeoutRef.current);
      }
    };
  }, []);

  const startMatrix = React.useCallback(() => {
    if (runningRef.current) {
      return;
    }

    runningRef.current = true;
    pressInCountRef.current = 0;
    pressCountRef.current = 0;
    const results: Array<RunResult> = [];

    const finishMatrix = () => {
      runningRef.current = false;
      animationRef.current?.stop();
      animationRef.current = null;

      const totalFreezeEpisodes = results.reduce(
        (sum, result) => sum + result.freezeEpisodes,
        0,
      );
      const maxFreezeMs = results.reduce(
        (max, result) => Math.max(max, result.maxFreezeMs),
        0,
      );
      const pressGap = pressInCountRef.current - pressCountRef.current;
      const lines = results.map(
        result =>
          `run ${result.run}: span=${result.span.toFixed(1)} ` +
          `freeze=${result.freezeEpisodes} max=${result.maxFreezeMs}ms ` +
          `duration=${result.durationMs}ms`,
      );
      const summary =
        `${lines.join('\n')}\n\n` +
        `samples/run: ${SAMPLES_PER_RUN}\n` +
        `total freeze episodes: ${totalFreezeEpisodes}\n` +
        `matrix max freeze: ${maxFreezeMs}ms\n` +
        `onPressIn: ${pressInCountRef.current}\n` +
        `onPress: ${pressCountRef.current}\n` +
        `press gap: ${pressGap}`;

      console.log(
        `[PG_MATRIX] ${JSON.stringify({
          sampleIntervalMs: SAMPLE_INTERVAL_MS,
          samplesPerRun: SAMPLES_PER_RUN,
          runs: results,
          totalFreezeEpisodes,
          maxFreezeMs,
          onPressIn: pressInCountRef.current,
          onPress: pressCountRef.current,
          pressGap,
        })}`,
      );
      Alert.alert('Presentation geometry matrix', summary);
    };

    const startRun = (runIndex: number) => {
      if (!mountedRef.current) {
        return;
      }

      animationRef.current?.stop();
      translateY.stopAnimation();
      translateY.setValue(0);

      const runStartedAt = Date.now();
      let minPageY = Number.POSITIVE_INFINITY;
      let maxPageY = Number.NEGATIVE_INFINITY;
      let sampleCount = 0;
      let previousPageY: ?number = null;
      let previousSampleAt: ?number = null;
      let stableRunStartedAt: ?number = null;
      let freezeEpisodeActive = false;
      let freezeEpisodes = 0;
      let maxFreezeMs = 0;
      let measurementPending = false;

      const animation = Animated.loop(
        Animated.sequence([
          Animated.timing(translateY, {
            toValue: 220,
            duration: 1400,
            easing: Easing.linear,
            useNativeDriver: true,
          }),
          Animated.timing(translateY, {
            toValue: 0,
            duration: 1400,
            easing: Easing.linear,
            useNativeDriver: true,
          }),
        ]),
      );
      animationRef.current = animation;
      animation.start();

      const finishRun = () => {
        if (intervalRef.current != null) {
          clearInterval(intervalRef.current);
          intervalRef.current = null;
        }
        animation.stop();
        animationRef.current = null;

        const result: RunResult = {
          run: runIndex + 1,
          minPageY,
          maxPageY,
          span: maxPageY - minPageY,
          samples: sampleCount,
          freezeEpisodes,
          maxFreezeMs,
          durationMs: Date.now() - runStartedAt,
        };
        results.push(result);
        console.log(`[PG_MATRIX] run ${result.run} ${JSON.stringify(result)}`);

        if (runIndex + 1 >= RUN_COUNT) {
          finishMatrix();
          return;
        }

        nextRunTimeoutRef.current = setTimeout(() => {
          nextRunTimeoutRef.current = null;
          startRun(runIndex + 1);
        }, RUN_GAP_MS);
      };

      intervalRef.current = setInterval(() => {
        const measuredView = measuredViewRef.current;
        if (
          !mountedRef.current ||
          measurementPending ||
          measuredView == null ||
          sampleCount >= SAMPLES_PER_RUN
        ) {
          return;
        }

        measurementPending = true;
        measuredView.measure(
          (_x, _y, _width, _height, _pageX, measuredPageY) => {
            measurementPending = false;
            if (!mountedRef.current) {
              return;
            }

            const now = Date.now();
            sampleCount += 1;
            minPageY = Math.min(minPageY, measuredPageY);
            maxPageY = Math.max(maxPageY, measuredPageY);

            const isPastWarmup = now - runStartedAt >= WARMUP_MS;
            if (
              isPastWarmup &&
              previousPageY != null &&
              previousSampleAt != null &&
              Math.abs(measuredPageY - previousPageY) <= FREEZE_EPSILON_PX
            ) {
              if (stableRunStartedAt == null) {
                stableRunStartedAt = previousSampleAt;
              }

              const freezeMs = now - stableRunStartedAt;
              maxFreezeMs = Math.max(maxFreezeMs, freezeMs);
              if (freezeMs >= FREEZE_THRESHOLD_MS && !freezeEpisodeActive) {
                freezeEpisodeActive = true;
                freezeEpisodes += 1;
              }
            } else {
              stableRunStartedAt = null;
              freezeEpisodeActive = false;
            }

            previousPageY = measuredPageY;
            previousSampleAt = now;

            if (sampleCount >= SAMPLES_PER_RUN) {
              finishRun();
            }
          },
        );
      }, SAMPLE_INTERVAL_MS);
    };

    startRun(0);
  }, [translateY]);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Presentation geometry matrix</Text>
      <Text style={styles.help}>
        Deterministic geometry-only test: 3 runs x 800 samples at 50 ms. No
        React state updates and no measurement marker mutations during a run.
        The full matrix takes about two minutes.
      </Text>

      <Pressable onPress={startMatrix} style={styles.reportButton}>
        <Text style={styles.reportButtonText}>START 3 x 800 MATRIX</Text>
      </Pressable>

      <Animated.View style={{transform: [{translateY}]}}>
        <Pressable
          onPressIn={() => {
            pressInCountRef.current += 1;
          }}
          onPress={() => {
            pressCountRef.current += 1;
          }}
          style={styles.button}>
          <View ref={measuredViewRef} collapsable={false}>
            <Text style={styles.buttonText}>PRESS WHILE MOVING</Text>
          </View>
        </Pressable>
      </Animated.View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: 24,
  },
  title: {
    color: 'white',
    fontSize: 20,
    fontWeight: '600',
    marginBottom: 8,
  },
  help: {
    color: '#d1d5db',
    maxWidth: 520,
    marginBottom: 16,
  },
  reportButton: {
    alignSelf: 'flex-start',
    borderColor: '#6b7280',
    borderRadius: 8,
    borderWidth: 1,
    marginBottom: 40,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  reportButtonText: {
    color: 'white',
    fontSize: 12,
    fontWeight: '600',
  },
  button: {
    alignSelf: 'flex-start',
    backgroundColor: '#2563eb',
    borderRadius: 12,
    paddingHorizontal: 20,
    paddingVertical: 16,
  },
  buttonText: {
    color: 'white',
    fontWeight: '700',
  },
});

export default {
  title: 'Presentation Geometry',
  name: 'presentation-geometry',
  description:
    'Runs a deterministic presentation-geometry matrix while native-driven transforms bypass ShadowTree commits.',
  render: (): React.Node => <PresentationGeometryExample />,
} as RNTesterModuleExample;
