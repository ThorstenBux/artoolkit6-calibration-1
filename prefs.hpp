/*
 *  prefs.hpp
 *  ARToolKit6
 *
 *  This file is part of ARToolKit.
 *
 *  ARToolKit is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Lesser General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  ARToolKit is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public License
 *  along with ARToolKit.  If not, see <http://www.gnu.org/licenses/>.
 *
 *  As a special exception, the copyright holders of this library give you
 *  permission to link this library with independent modules to produce an
 *  executable, regardless of the license terms of these independent modules, and to
 *  copy and distribute the resulting executable under terms of your choice,
 *  provided that you also meet, for each linked independent module, the terms and
 *  conditions of the license of that module. An independent module is a module
 *  which is neither derived from nor based on this library. If you modify this
 *  library, you may extend this exception to your version of the library, but you
 *  are not obligated to do so. If you do not wish to do so, delete this exception
 *  statement from your version.
 *
 *  Copyright 2017-2017 Daqri LLC. All Rights Reserved.
 *
 *  Author(s): Philip Lamb
 *
 */

#ifndef prefs_hpp
#define prefs_hpp

#include "Calibration.hpp"


// Data upload.
#define CALIBRATION_SERVER_UPLOAD_URL_DEFAULT "https://omega.artoolworks.com/app/calib_camera/upload.php"
// Until we implement nonce-based hashing, use of the plain md5 of the calibration server authentication token is vulnerable to replay attack.
// The calibration server authentication token itself needs to be hidden in the binary.
#define CALIBRATION_SERVER_AUTHENTICATION_TOKEN_DEFAULT "com.artoolworks.utils.calib_camera.116D5A95-E17B-266E-39E4-E5DED6C07C53" // MD5 = {0x32, 0x57, 0x5a, 0x6f, 0x69, 0xa4, 0x11, 0x5a, 0x25, 0x49, 0xae, 0x55, 0x6b, 0xd2, 0x2a, 0xda}
#define CALIBRATION_PATTERN_TYPE_DEFAULT Calibration::CalibrationPatternType::CHESSBOARD

#ifdef __cplusplus
extern "C" {
#endif

void *initPreferences(void);
void showPreferences(void *preferences);
void preferencesFinal(void **preferences_p);

char *getPreferenceCameraOpenToken(void *preferences);
char *getPreferenceCameraResolutionToken(void *preferences);
char *getPreferenceCalibrationServerUploadURL(void *preferences);
char *getPreferenceCalibrationServerAuthenticationToken(void *preferences);
Calibration::CalibrationPatternType getPreferencesCalibrationPatternType(void *preferences);
cv::Size getPreferencesCalibrationPatternSize(void *preferences);
float getPreferencesCalibrationPatternSpacing(void *preferences);


#ifdef __cplusplus
}
#endif
#endif /* prefs_hpp */