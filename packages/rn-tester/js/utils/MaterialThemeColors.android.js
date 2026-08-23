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

/**
 * Semantic Material color roles resolved by Android from the Activity theme.
 * On Android 12+ RNTester applies Dynamic Colors, so these values follow the
 * device / wallpaper Material You palette without duplicating it in JS.
 */
const MaterialThemeColors = {
  surface: PlatformColor(
    '?attr/colorSurface',
    '?android:attr/colorBackground',
  ),
  surfaceContainer: PlatformColor(
    '?attr/colorSurfaceContainer',
    '?attr/colorSurfaceVariant',
    '?attr/colorSurface',
  ),
  onSurface: PlatformColor(
    '?attr/colorOnSurface',
    '?android:attr/textColorPrimary',
  ),
  onSurfaceVariant: PlatformColor(
    '?attr/colorOnSurfaceVariant',
    '?android:attr/textColorSecondary',
  ),
  primary: PlatformColor('?attr/colorPrimary', '?attr/colorAccent'),
  onPrimary: PlatformColor(
    '?attr/colorOnPrimary',
    '?android:attr/textColorPrimaryInverse',
  ),
  outline: PlatformColor(
    '?attr/colorOutline',
    '?android:attr/textColorSecondary',
  ),
};

export default MaterialThemeColors;
