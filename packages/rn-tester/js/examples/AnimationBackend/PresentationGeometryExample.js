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
import {Animated, Pressable, StyleSheet, Text, View} from 'react-native';

function PresentationGeometryExample(): React.Node {
  const translateY = React.useRef(new Animated.Value(0)).current;
  const measuredViewRef = React.useRef<React.ElementRef<typeof View> | null>(
    null,
  );
  const [pageY, setPageY] = React.useState<?number>(null);
  const [pressInCount, setPressInCount] = React.useState(0);
  const [pressCount, setPressCount] = React.useState(0);

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
      measuredViewRef.current?.measure(
        (_x, _y, _width, _height, _pageX, measuredPageY) => {
          setPageY(measuredPageY);
        },
      );
    }, 100);
    return () => clearInterval(interval);
  }, []);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Presentation geometry proof</Text>
      <Text style={styles.help}>
        The button is moved only by a native-driven transform. The measured
        pageY should move with it, and presses should complete at every visual
        position.
      </Text>
      <View style={styles.readout}>
        <Text>measured pageY: {pageY == null ? '—' : pageY.toFixed(1)}</Text>
        <Text>onPressIn: {pressInCount}</Text>
        <Text>onPress: {pressCount}</Text>
      </View>
      <Animated.View style={{transform: [{translateY}]}}>
        <Pressable
          onPressIn={() => setPressInCount(value => value + 1)}
          onPress={() => setPressCount(value => value + 1)}
          style={({pressed}) => [styles.button, pressed && styles.pressed]}>
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
    fontSize: 20,
    fontWeight: '600',
    marginBottom: 8,
  },
  help: {
    maxWidth: 520,
    marginBottom: 16,
  },
  readout: {
    gap: 4,
    marginBottom: 40,
  },
  button: {
    alignSelf: 'flex-start',
    backgroundColor: '#2563eb',
    borderRadius: 12,
    paddingHorizontal: 20,
    paddingVertical: 16,
  },
  pressed: {
    opacity: 0.7,
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
    'Tests geometry and Pressability while native-driven transforms bypass ShadowTree commits.',
  render: (): React.Node => <PresentationGeometryExample />,
} as RNTesterModuleExample;
