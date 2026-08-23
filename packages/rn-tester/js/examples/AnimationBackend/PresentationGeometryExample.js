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

const PROTOCOL = 'PG_CONTINUOUS_V3';
const SAMPLE_INTERVAL_MS = 50;
const RUN_COUNT = 3;
const RUN_GAP_MS = 300;
const SWEEP_DURATION_MS = 15000;
const SAMPLE_WINDOW_MS = 6000;
const SWEEP_DISTANCE_PX = 300;

type RunResult = {
  run: number,
  samples: number,
  observedDelta: number,
  expectedDelta: number,
  trackingRatio: number,
  meanAbsError: number,
  maxAbsError: number,
  durationMs: number,
};

function PresentationGeometryExample(): React.Node {
  const translateY = React.useRef(new Animated.Value(0)).current;
  const measuredViewRef = React.useRef<any>(null);
  const runningRef = React.useRef(false);
  const mountedRef = React.useRef(true);
  const animationRef = React.useRef<?{stop: () => void}>(null);
  const intervalRef = React.useRef<?IntervalID>(null);
  const runTimeoutRef = React.useRef<?TimeoutID>(null);
  const nextRunTimeoutRef = React.useRef<?TimeoutID>(null);

  React.useEffect(() => {
    return () => {
      mountedRef.current = false;
      animationRef.current?.stop();
      if (intervalRef.current != null) {
        clearInterval(intervalRef.current);
      }
      if (runTimeoutRef.current != null) {
        clearTimeout(runTimeoutRef.current);
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
    const results: Array<RunResult> = [];

    const finishMatrix = () => {
      runningRef.current = false;
      animationRef.current?.stop();
      animationRef.current = null;

      const lines = results.map(
        result =>
          `run ${result.run}: samples=${result.samples} ` +
          `observed=${result.observedDelta.toFixed(1)} ` +
          `expected=${result.expectedDelta.toFixed(1)} ` +
          `ratio=${result.trackingRatio.toFixed(3)} ` +
          `mae=${result.meanAbsError.toFixed(1)} ` +
          `maxErr=${result.maxAbsError.toFixed(1)} ` +
          `duration=${result.durationMs}ms`,
      );
      const summary =
        `protocol: ${PROTOCOL}\n` +
        `${lines.join('\n')}\n\n` +
        `window: ${SAMPLE_WINDOW_MS}ms\n` +
        `sweep: ${SWEEP_DISTANCE_PX}px / ${SWEEP_DURATION_MS}ms`;

      console.log(
        `[PG_MATRIX_V3] ${JSON.stringify({
          protocol: PROTOCOL,
          sampleIntervalMs: SAMPLE_INTERVAL_MS,
          sampleWindowMs: SAMPLE_WINDOW_MS,
          sweepDurationMs: SWEEP_DURATION_MS,
          sweepDistancePx: SWEEP_DISTANCE_PX,
          runs: results,
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
      let runFinished = false;
      let measurementPending = false;
      let sampleCount = 0;
      let firstSampleAt: ?number = null;
      let firstPageY: ?number = null;
      let lastSampleAt: ?number = null;
      let lastPageY: ?number = null;
      let errorSum = 0;
      let errorSamples = 0;
      let maxAbsError = 0;

      const finishRun = () => {
        if (runFinished) {
          return;
        }
        runFinished = true;

        if (intervalRef.current != null) {
          clearInterval(intervalRef.current);
          intervalRef.current = null;
        }
        if (runTimeoutRef.current != null) {
          clearTimeout(runTimeoutRef.current);
          runTimeoutRef.current = null;
        }
        animationRef.current?.stop();
        animationRef.current = null;

        const sampleDuration =
          firstSampleAt != null && lastSampleAt != null
            ? Math.max(0, lastSampleAt - firstSampleAt)
            : 0;
        const observedDelta =
          firstPageY != null && lastPageY != null ? lastPageY - firstPageY : 0;
        const expectedDelta =
          (SWEEP_DISTANCE_PX * sampleDuration) / SWEEP_DURATION_MS;
        const trackingRatio =
          expectedDelta > 0 ? observedDelta / expectedDelta : 0;
        const result: RunResult = {
          run: runIndex + 1,
          samples: sampleCount,
          observedDelta,
          expectedDelta,
          trackingRatio,
          meanAbsError: errorSamples > 0 ? errorSum / errorSamples : 0,
          maxAbsError,
          durationMs: Date.now() - runStartedAt,
        };
        results.push(result);
        console.log(`[PG_MATRIX_V3] run ${result.run} ${JSON.stringify(result)}`);

        if (runIndex + 1 >= RUN_COUNT) {
          finishMatrix();
          return;
        }

        nextRunTimeoutRef.current = setTimeout(() => {
          nextRunTimeoutRef.current = null;
          startRun(runIndex + 1);
        }, RUN_GAP_MS);
      };

      const animation = Animated.timing(translateY, {
        toValue: SWEEP_DISTANCE_PX,
        duration: SWEEP_DURATION_MS,
        easing: Easing.linear,
        useNativeDriver: true,
      });
      animationRef.current = animation;
      animation.start();

      intervalRef.current = setInterval(() => {
        if (runFinished || measurementPending || !mountedRef.current) {
          return;
        }
        const measuredView = measuredViewRef.current;
        if (measuredView == null) {
          return;
        }

        measurementPending = true;
        measuredView.measure(
          (_x, _y, _width, _height, _pageX, measuredPageY) => {
            measurementPending = false;
            if (runFinished || !mountedRef.current) {
              return;
            }

            const now = Date.now();
            if (firstSampleAt == null || firstPageY == null) {
              firstSampleAt = now;
              firstPageY = measuredPageY;
            }

            sampleCount += 1;
            lastSampleAt = now;
            lastPageY = measuredPageY;

            const elapsedFromFirst = Math.max(0, now - firstSampleAt);
            const expectedDelta =
              (SWEEP_DISTANCE_PX * elapsedFromFirst) / SWEEP_DURATION_MS;
            const observedDelta = measuredPageY - firstPageY;
            const absError = Math.abs(observedDelta - expectedDelta);
            errorSum += absError;
            errorSamples += 1;
            maxAbsError = Math.max(maxAbsError, absError);

            if (now - runStartedAt >= SAMPLE_WINDOW_MS) {
              finishRun();
            }
          },
        );
      }, SAMPLE_INTERVAL_MS);

      runTimeoutRef.current = setTimeout(finishRun, SAMPLE_WINDOW_MS);
    };

    startRun(0);
  }, [translateY]);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Presentation geometry continuous sweep</Text>
      <Text style={styles.help}>
        Protocol {PROTOCOL}: three one-way 15 second native-driven sweeps. Each
        run samples for exactly 6 seconds and compares measured movement with
        the movement expected from the animation clock. No loops, reversals,
        endpoint waits, React state updates, or marker mutations occur during a
        run.
      </Text>

      <Pressable onPress={startMatrix} style={styles.reportButton}>
        <Text style={styles.reportButtonText}>START CONTINUOUS V3</Text>
      </Pressable>

      <Animated.View
        ref={measuredViewRef}
        collapsable={false}
        style={[styles.button, {transform: [{translateY}]}]}>
        <Text style={styles.buttonText}>MEASURE THIS MOVING VIEW</Text>
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
    'Runs time-bounded native-driven sweeps and compares measured presentation movement against the animation clock.',
  render: (): React.Node => <PresentationGeometryExample />,
} as RNTesterModuleExample;