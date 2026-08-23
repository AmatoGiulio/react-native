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
  Pressable,
  StyleSheet,
  Text,
  View,
} from 'react-native';

function PresentationGeometryExample(): React.Node {
  const translateY = React.useRef(new Animated.Value(0)).current;
  const measuredMarkerY = React.useRef(new Animated.Value(0)).current;
  const rootRef = React.useRef<React.ElementRef<typeof View> | null>(null);
  const measuredViewRef = React.useRef<React.ElementRef<typeof View> | null>(
    null,
  );
  const minPageYRef = React.useRef<number>(Number.POSITIVE_INFINITY);
  const maxPageYRef = React.useRef<number>(Number.NEGATIVE_INFINITY);
  const pressInCountRef = React.useRef(0);
  const pressCountRef = React.useRef(0);

  React.useEffect(() => {
    const animation = Animated.loop(
      Animated.sequence([
        Animated.timing(translateY, {
          toValue: 220,
          duration: 1400,
          useNativeDriver: true,
        }),
        Animated.timing(translateY, {
          toValue: 0,
          duration: 1400,
          useNativeDriver: true,
        }),
      ]),
    );
    animation.start();
    return () => animation.stop();
  }, [translateY]);

  React.useEffect(() => {
    const interval = setInterval(() => {
      rootRef.current?.measure(
        (_rootX, _rootY, _rootWidth, _rootHeight, _rootPageX, rootPageY) => {
          measuredViewRef.current?.measure(
            (_x, _y, _width, _height, _pageX, measuredPageY) => {
              minPageYRef.current = Math.min(
                minPageYRef.current,
                measuredPageY,
              );
              maxPageYRef.current = Math.max(
                maxPageYRef.current,
                measuredPageY,
              );
              measuredMarkerY.setValue(measuredPageY - rootPageY);
              console.log(`[PG] measured pageY=${measuredPageY.toFixed(1)}`);
            },
          );
        },
      );
    }, 100);
    return () => clearInterval(interval);
  }, [measuredMarkerY]);

  const reportResults = React.useCallback(() => {
    const minPageY = minPageYRef.current;
    const maxPageY = maxPageYRef.current;
    const hasMeasurements =
      Number.isFinite(minPageY) && Number.isFinite(maxPageY);
    const range = hasMeasurements ? maxPageY - minPageY : 0;

    Alert.alert(
      'Presentation geometry results',
      `pageY min: ${hasMeasurements ? minPageY.toFixed(1) : '—'}\n` +
        `pageY max: ${hasMeasurements ? maxPageY.toFixed(1) : '—'}\n` +
        `pageY span: ${hasMeasurements ? range.toFixed(1) : '—'}\n` +
        `onPressIn: ${pressInCountRef.current}\n` +
        `onPress: ${pressCountRef.current}`,
    );
  }, []);

  return (
    <View ref={rootRef} collapsable={false} style={styles.container}>
      <Text style={styles.title}>Presentation geometry proof</Text>
      <Text style={styles.help}>
        No React state is updated while this test runs. The red line shows the
        current measure() result. Press the moving button around 20 times, then
        tap REPORT RESULTS.
      </Text>

      <Pressable onPress={reportResults} style={styles.reportButton}>
        <Text style={styles.reportButtonText}>REPORT RESULTS</Text>
      </Pressable>

      <Animated.View
        pointerEvents="none"
        style={[styles.measureMarker, {transform: [{translateY: measuredMarkerY}]}]}
      />

      <Animated.View style={{transform: [{translateY}]}}>
        <Pressable
          onPressIn={() => {
            pressInCountRef.current += 1;
            console.log(`[PG] onPressIn=${pressInCountRef.current}`);
          }}
          onPress={() => {
            pressCountRef.current += 1;
            console.log(`[PG] onPress=${pressCountRef.current}`);
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
  measureMarker: {
    position: 'absolute',
    left: 0,
    right: 0,
    top: 0,
    height: 2,
    backgroundColor: '#ef4444',
    zIndex: 20,
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
    'Tests geometry and Pressability while native-driven transforms bypass ShadowTree commits without introducing observation commits.',
  render: (): React.Node => <PresentationGeometryExample />,
} as RNTesterModuleExample;
