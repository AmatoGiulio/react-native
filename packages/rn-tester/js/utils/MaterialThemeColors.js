/**
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @flow strict-local
 * @format
 */

import {PlatformColor} from 'react-native';

const MaterialThemeColors = {
  surface: PlatformColor('systemBackgroundColor'),
  surfaceContainer: PlatformColor('secondarySystemBackgroundColor'),
  onSurface: PlatformColor('labelColor'),
  onSurfaceVariant: PlatformColor('secondaryLabelColor'),
  primary: PlatformColor('systemBlueColor'),
  onPrimary: PlatformColor('systemBackgroundColor'),
  outline: PlatformColor('separatorColor'),
};

export default MaterialThemeColors;
