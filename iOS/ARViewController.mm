/*
 *  ARViewController.mm
 *  ARToolKit6 Camera Calibration Utility
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
 *  Copyright 2015-2017 Daqri, LLC.
 *  Copyright 2008-2015 ARToolworks, Inc.
 *
 *  Author(s): Philip Lamb
 *
 */


#import "ARViewController.h"
#import <OpenGLES/ES2/glext.h>
#import "CameraFocusView.h"
#ifdef DEBUG
#  import <unistd.h>
#  import <sys/param.h>
#endif

#include <AR6/AR/ar.h>
#include <AR6/ARVideoSource.h>
#include <AR6/ARView.h>
#include <AR6/ARUtil/system.h>
#include <AR6/ARUtil/thread_sub.h>
#include <AR6/ARUtil/time.h>
#include <AR6/ARG/arg.h>
#include <AR6/ARG/arg_mtx.h>
#include <AR6/ARG/arg_shader_gl.h>

#include "fileUploader.h"
#include "Calibration.hpp"
#include "calc.h"
#include "flow.h"
#include "Eden/EdenMessage.h"
#include "Eden/EdenGLFont.h"


#include "prefs.h"

//#import "draw.h"

// ============================================================================
//	Constants
// ============================================================================

// Indices of GL ES program uniforms.
enum {
    UNIFORM_MODELVIEW_PROJECTION_MATRIX,
    UNIFORM_COLOR,
    UNIFORM_COUNT
};
// Indices of of GL ES program attributes.
enum {
    ATTRIBUTE_VERTEX,
    ATTRIBUTE_COUNT
};


#define      CHESSBOARD_CORNER_NUM_X        7
#define      CHESSBOARD_CORNER_NUM_Y        5
#define      CHESSBOARD_PATTERN_WIDTH      30.0
#define      CALIB_IMAGE_NUM               10
#define      SAVE_FILENAME                 "camera_para.dat"

// Data upload.
#define QUEUE_DIR "queue"
#define QUEUE_INDEX_FILE_EXTENSION "upload"



#ifdef __APPLE__
#  include <CommonCrypto/CommonDigest.h>
#  define MD5 CC_MD5
#  define MD5_DIGEST_LENGTH CC_MD5_DIGEST_LENGTH
#  define MD5_COUNT_t CC_LONG
#else
//#include <openssl/md5.h>
// Rather than including full OpenSSL header tree, just provide prototype for MD5().
// Usage is here: https://www.openssl.org/docs/manmaster/man3/MD5.html .
#  define MD5_DIGEST_LENGTH 16
#  define MD5_COUNT_t size_t
#  ifdef __cplusplus
extern "C" {
#  endif
    unsigned char *MD5(const unsigned char *d, size_t n, unsigned char *md);
#  ifdef __cplusplus
}
#  endif
#endif

// Data upload.
#define CALIBRATION_SERVER_UPLOAD_URL_DEFAULT "https://omega.artoolworks.com/app/calib_camera/upload.php"
// Until we implement nonce-based hashing, use of the plain md5 of the calibration server authentication token is vulnerable to replay attack.
// The calibration server authentication token itself needs to be hidden in the binary.
#define CALIBRATION_SERVER_AUTHENTICATION_TOKEN_DEFAULT "com.artoolworks.utils.calib_camera.116D5A95-E17B-266E-39E4-E5DED6C07C53" // MD5 = {0x32, 0x57, 0x5a, 0x6f, 0x69, 0xa4, 0x11, 0x5a, 0x25, 0x49, 0xae, 0x55, 0x6b, 0xd2, 0x2a, 0xda}

#define FONT_SIZE 18.0f
#define UPLOAD_STATUS_HIDE_AFTER_SECONDS 9.0f


static void saveParam(const ARParam *param, ARdouble err_min, ARdouble err_avg, ARdouble err_max, void *userdata);

@interface ARViewController () {

    // Prefs.
    int gPreferencesCalibImageCountMax;
    int gPreferencesChessboardCornerNumX;
    int gPreferencesChessboardCornerNumY;
    float gPreferencesChessboardSquareWidth;
    
    void *gPreferences;
    //Uint32 gSDLEventPreferencesChanged;
    char *gPreferenceCameraOpenToken;
    char *gPreferenceCameraResolutionToken;
    char *gCalibrationServerUploadURL;
    char *gCalibrationServerAuthenticationToken;

    //
    // Calibration.
    //
    
    Calibration *gCalibration;
    
    //
    // Data upload.
    //
    
    char *gFileUploadQueuePath;
    FILE_UPLOAD_HANDLE_t *fileUploadHandle;
    


    // Video acquisition and rendering.
    ARVideoSource *vs;
    ARView *vv;
    bool gPostVideoSetupDone;
    bool gCameraIsFrontFacing;
    
    // Marker detection.
    long            gCallCountMarkerDetect;
    BOOL drawRequired;

    // Window and GL context.
    int contextWidth;
    int contextHeight;
    bool contextWasUpdated;
    int32_t gViewport[4];
    int gDisplayOrientation; // range [0-3]. 1=landscape.
    float gDisplayDPI;
    GLint uniforms[UNIFORM_COUNT];
    GLuint program;
    CameraFocusView *focusView;

    // Main state.
    struct timeval gStartTime;

    // Corner finder results copy, for display to user.
    ARGL_CONTEXT_SETTINGS_REF gArglSettingsCornerFinderImage;
}

@property (strong, nonatomic) EAGLContext *context;

- (void)setupGL;
- (void)tearDownGL;
- (void) drawCleanupGLES2;
@end

@implementation ARViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    // Init instance variables.
    gPreferencesCalibImageCountMax = 0;
    gPreferencesChessboardCornerNumX = 0;
    gPreferencesChessboardCornerNumY = 0;
    gPreferencesChessboardSquareWidth = 0.0f;
    gPreferences = NULL;
    //gSDLEventPreferencesChanged = 0;
    gPreferenceCameraOpenToken = NULL;
    gPreferenceCameraResolutionToken = NULL;
    gCalibrationServerUploadURL = NULL;
    gCalibrationServerAuthenticationToken = NULL;
    gCalibration = nullptr;
    gFileUploadQueuePath = NULL;
    fileUploadHandle = NULL;
    vs = nullptr;
    vv = nullptr;
    gPostVideoSetupDone = false;
    gCameraIsFrontFacing = false;
    gCallCountMarkerDetect = 0L;
    drawRequired = FALSE;
    contextWidth = 0;
    contextHeight = 0;
    contextWasUpdated = false;
    gViewport[0] =  gViewport[1] = gViewport[2] = gViewport[3] = 0;
    gDisplayOrientation = 0; // range [0-3]. 0=portrait, 1=landscape.
    gDisplayDPI = 72.0f;
    uniforms[0] = 0;
    program = 0;
    gArglSettingsCornerFinderImage = NULL;
    
    // Preferences.
    gPreferences = initPreferences();
    gPreferenceCameraOpenToken = getPreferenceCameraOpenToken(gPreferences);
    gPreferenceCameraResolutionToken = getPreferenceCameraResolutionToken(gPreferences);
    gCalibrationServerUploadURL = getPreferenceCalibrationServerUploadURL(gPreferences);
    if (!gCalibrationServerUploadURL) gCalibrationServerUploadURL = strdup(CALIBRATION_SERVER_UPLOAD_URL_DEFAULT);
    gCalibrationServerAuthenticationToken = getPreferenceCalibrationServerAuthenticationToken(gPreferences);
    if (!gCalibrationServerAuthenticationToken) gCalibrationServerAuthenticationToken = strdup(CALIBRATION_SERVER_AUTHENTICATION_TOKEN_DEFAULT);
    //gSDLEventPreferencesChanged = SDL_RegisterEvents(1);
    
    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];

    if (!self.context) {
        NSLog(@"Failed to create ES context");
    }
    
    GLKView *view = (GLKView *)self.view;
    view.context = self.context;
    view.drawableDepthFormat = GLKViewDrawableDepthFormat24;
    
    [[NSBundle mainBundle] loadNibNamed:@"ARViewOverlays" owner:self options:nil]; // Contains connection to the strong property "overlays".
    self.overlays.frame = self.view.frame;
    if (!focusView) focusView = [[CameraFocusView alloc] initWithFrame:self.view.frame];
    
    [self setupGL];
    
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    // Extra view setup.
    [self.view addSubview:self.overlays];
    //self.view.touchDelegate = self;
    [self.view addSubview:focusView];
    
}

- (void)viewDidLayoutSubviews
{
    GLKView *view = (GLKView *)self.view;
    [view bindDrawable];
    contextWidth = (int)view.drawableWidth;
    contextHeight = (int)view.drawableHeight;
    contextWasUpdated = true;
}

- (void)viewDidDisappear:(BOOL)animated
{
    // Extra view cleanup.
    [self.overlays removeFromSuperview];
    //self.view.touchDelegate = nil;
    [focusView removeFromSuperview];

    [super viewDidDisappear:animated];
}


- (void)dealloc
{    
    [self tearDownGL];
    
    if ([EAGLContext currentContext] == self.context) {
        [EAGLContext setCurrentContext:nil];
    }
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];

    if ([self isViewLoaded] && ([[self view] window] == nil)) {
        self.view = nil;
        
        [self tearDownGL];
        
        if ([EAGLContext currentContext] == self.context) {
            [EAGLContext setCurrentContext:nil];
        }
        self.context = nil;
    }

    // Dispose of any resources that can be recreated.
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)startVideo
{
    char buf[256];
    snprintf(buf, sizeof(buf), "%s %s", (gPreferenceCameraOpenToken ? gPreferenceCameraOpenToken : ""), (gPreferenceCameraResolutionToken ? gPreferenceCameraResolutionToken : ""));
    
    vs = new ARVideoSource;
    if (!vs) {
        ARLOGe("Error: Unable to create video source.\n");
        //quit(-1);
    }
    vs->configure(buf, true, NULL, NULL, 0);
    if (!vs->open()) {
        ARLOGe("Error: Unable to open video source.\n");
        //quit(-1);
    }
    gPostVideoSetupDone = false;
}

- (void)stopVideo
{
    delete vv;
    vv = nullptr;
    delete vs;
    vs = nullptr;
}

- (void)setupGL
{
    [EAGLContext setCurrentContext:self.context];
    
    
#ifdef DEBUG
    arLogLevel = AR_LOG_LEVEL_DEBUG;
#endif
 
    asprintf(&gFileUploadQueuePath, "%s/%s", arUtilGetResourcesDirectoryPath(AR_UTIL_RESOURCES_DIRECTORY_BEHAVIOR_USE_APP_CACHE_DIR), QUEUE_DIR);
    // Check for QUEUE_DIR and create if not already existing.
    if (!fileUploaderCreateQueueDir(gFileUploadQueuePath)) {
        ARLOGe("Error: Could not create queue directory.\n");
        exit(-1);
    }
    
    fileUploadHandle = fileUploaderInit(gFileUploadQueuePath, QUEUE_INDEX_FILE_EXTENSION, gCalibrationServerUploadURL, UPLOAD_STATUS_HIDE_AFTER_SECONDS);
    if (!fileUploadHandle) {
        ARLOGe("Error: Could not initialise fileUploadHandle.\n");
        exit(-1);
    }
    fileUploaderTickle(fileUploadHandle);
    
    // Calibration prefs.
    if( gPreferencesChessboardCornerNumX == 0 ) gPreferencesChessboardCornerNumX = CHESSBOARD_CORNER_NUM_X;
    if( gPreferencesChessboardCornerNumY == 0 ) gPreferencesChessboardCornerNumY = CHESSBOARD_CORNER_NUM_Y;
    if( gPreferencesCalibImageCountMax == 0 )        gPreferencesCalibImageCountMax = CALIB_IMAGE_NUM;
    if( gPreferencesChessboardSquareWidth == 0.0f )       gPreferencesChessboardSquareWidth = (float)CHESSBOARD_PATTERN_WIDTH;
    ARLOGi("CHESSBOARD_CORNER_NUM_X = %d\n", gPreferencesChessboardCornerNumX);
    ARLOGi("CHESSBOARD_CORNER_NUM_Y = %d\n", gPreferencesChessboardCornerNumY);
    ARLOGi("CHESSBOARD_PATTERN_WIDTH = %f\n", gPreferencesChessboardSquareWidth);
    ARLOGi("CALIB_IMAGE_NUM = %d\n", gPreferencesCalibImageCountMax);
    
    // Library setup.
    int contextsActiveCount = 1;
//    EdenMessageInit(contextsActiveCount);
//    EdenGLFontInit(contextsActiveCount);
//    EdenGLFontSetFont(EDEN_GL_FONT_ID_Stroke_Roman);
//    EdenGLFontSetSize(FONT_SIZE);
    
    // Get start time.
    gettimeofday(&gStartTime, NULL);
    
    [self startVideo];
}

- (void)tearDownGL
{
    [EAGLContext setCurrentContext:self.context];
    
    [self drawCleanupGLES2];

}

#pragma mark - GLKView and GLKViewController delegate methods

- (void)update
{
    if (vs->isOpen()) {
        if (vs->captureFrame()) {
            gCallCountMarkerDetect++; // Increment ARToolKit FPS counter.
#ifdef DEBUG
            if (gCallCountMarkerDetect % 150 == 0) {
                ARLOGi("*** Camera - %f (frame/sec)\n", (double)gCallCountMarkerDetect/arUtilTimer());
                gCallCountMarkerDetect = 0;
                arUtilTimerReset();
            }
#endif
            drawRequired = TRUE;
        }
        
    } // vs->isOpen()

}


- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    GLfloat p[16], m[16];
    int i;
    struct timeval time;
    float left, right, bottom, top;
    GLfloat *vertices = NULL;
    GLint vertexCount;
    
    if (!drawRequired) return;
    
    // Get frame time.
    gettimeofday(&time, NULL);
    
    if (!gPostVideoSetupDone) {
        
        gCameraIsFrontFacing = false;
        AR2VideoParamT *vid = vs->getAR2VideoParam();
        
        if (vid->module == AR_VIDEO_MODULE_AVFOUNDATION) {
            int frontCamera;
            if (ar2VideoGetParami(vid, AR_VIDEO_PARAM_AVFOUNDATION_CAMERA_POSITION, &frontCamera) >= 0) {
                gCameraIsFrontFacing = (frontCamera == AR_VIDEO_AVFOUNDATION_CAMERA_POSITION_FRONT);
            }
        }
        bool contentRotate90, contentFlipV, contentFlipH;
        if (gDisplayOrientation == 1) { // Landscape with top of device at left.
            contentRotate90 = false;
            contentFlipV = gCameraIsFrontFacing;
            contentFlipH = gCameraIsFrontFacing;
        } else if (gDisplayOrientation == 2) { // Portrait upside-down.
            contentRotate90 = true;
            contentFlipV = !gCameraIsFrontFacing;
            contentFlipH = true;
        } else if (gDisplayOrientation == 3) { // Landscape with top of device at right.
            contentRotate90 = false;
            contentFlipV = !gCameraIsFrontFacing;
            contentFlipH = (!gCameraIsFrontFacing);
        } else /*(gDisplayOrientation == 0)*/ { // Portait
            contentRotate90 = true;
            contentFlipV = gCameraIsFrontFacing;
            contentFlipH = false;
        }
        
        // Setup a route for rendering the color background image.
        vv = new ARView;
        if (!vv) {
            ARLOGe("Error: unable to create video view.\n");
            //quit(-1);
        }
        vv->setRotate90(contentRotate90);
        vv->setFlipH(contentFlipH);
        vv->setFlipV(contentFlipV);
        vv->setScalingMode(ARView::ScalingMode::SCALE_MODE_FIT);
        vv->initWithVideoSource(*vs, contextWidth, contextHeight);
        ARLOGi("Content %dx%d (wxh) will display in GL context %dx%d%s.\n", vs->getVideoWidth(), vs->getVideoHeight(), contextWidth, contextHeight, (contentRotate90 ? " rotated" : ""));
        vv->getViewport(gViewport);
        
        // Setup a route for rendering the mono background image.
        ARParam idealParam;
        arParamClear(&idealParam, vs->getVideoWidth(), vs->getVideoHeight(), AR_DIST_FUNCTION_VERSION_DEFAULT);
        if ((gArglSettingsCornerFinderImage = arglSetupForCurrentContext(&idealParam, AR_PIXEL_FORMAT_MONO)) == NULL) {
            ARLOGe("Unable to setup argl.\n");
            //quit(-1);
        }
        if (!arglDistortionCompensationSet(gArglSettingsCornerFinderImage, FALSE)) {
            ARLOGe("Unable to setup argl.\n");
            //quit(-1);
        }
        arglSetRotate90(gArglSettingsCornerFinderImage, contentRotate90);
        arglSetFlipV(gArglSettingsCornerFinderImage, contentFlipV);
        arglSetFlipH(gArglSettingsCornerFinderImage, contentFlipH);
        
        //
        // Calibration init.
        //
        
        gCalibration = new Calibration(gPreferencesCalibImageCountMax, gPreferencesChessboardCornerNumX, gPreferencesChessboardCornerNumY, gPreferencesChessboardSquareWidth, vs->getVideoWidth(), vs->getVideoHeight());
        if (!gCalibration) {
            ARLOGe("Error initialising calibration.\n");
            exit (-1);
        }
        
        if (!flowInitAndStart(gCalibration, saveParam, (__bridge void *)self)) {
            ARLOGe("Error: Could not initialise and start flow.\n");
            //quit(-1);
        }
        
        // For FPS statistics.
        arUtilTimerReset();
        gCallCountMarkerDetect = 0;
        
        gPostVideoSetupDone = true;
    } // !gPostVideoSetupDone
    
    if (contextWasUpdated) {
        vv->setContextSize({contextWidth, contextHeight});
        vv->getViewport(gViewport);
    }
    
    FLOW_STATE state = flowStateGet();
    if (state == FLOW_STATE_WELCOME || state == FLOW_STATE_DONE || state == FLOW_STATE_CALIBRATING) {
        
        // Upload the frame to OpenGL.
        // Now done as part of the draw call.
        
    } else if (state == FLOW_STATE_CAPTURING) {
        
        gCalibration->frame(vs);
        
    }
    
    // The display has changed.
    
    // Clean the OpenGL context.
    glClearColor(0.0, 0.0, 0.0, 1.0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    
    if (!program) {
        GLuint vertShader = 0, fragShader = 0;
        // A simple shader pair which accepts just a vertex position. Fixed color, no lighting.
        const char vertShaderString[] =
        "attribute vec4 position;\n"
        "uniform vec4 color;\n"
        "uniform mat4 modelViewProjectionMatrix;\n"
        
        "varying vec4 colorVarying;\n"
        "void main()\n"
        "{\n"
            "gl_Position = modelViewProjectionMatrix * position;\n"
            "colorVarying = color;\n"
        "}\n";
        const char fragShaderString[] =
        "#ifdef GL_ES\n"
            "precision mediump float;\n"
        "#endif\n"
        "varying vec4 colorVarying;\n"
        "void main()\n"
        "{\n"
            "gl_FragColor = colorVarying;\n"
        "}\n";
        
        if (program) arglGLDestroyShaders(0, 0, program);
        program = glCreateProgram();
        if (!program) {
            ARLOGe("draw: Error creating shader program.\n");
            return;
        }
        
        if (!arglGLCompileShaderFromString(&vertShader, GL_VERTEX_SHADER, vertShaderString)) {
            ARLOGe("draw: Error compiling vertex shader.\n");
            arglGLDestroyShaders(vertShader, fragShader, program);
            program = 0;
            return;
        }
        if (!arglGLCompileShaderFromString(&fragShader, GL_FRAGMENT_SHADER, fragShaderString)) {
            ARLOGe("draw: Error compiling fragment shader.\n");
            arglGLDestroyShaders(vertShader, fragShader, program);
            program = 0;
            return;
        }
        glAttachShader(program, vertShader);
        glAttachShader(program, fragShader);
        
        glBindAttribLocation(program, ATTRIBUTE_VERTEX, "position");
        if (!arglGLLinkProgram(program)) {
            ARLOGe("draw: Error linking shader program.\n");
            arglGLDestroyShaders(vertShader, fragShader, program);
            program = 0;
            return;
        }
        arglGLDestroyShaders(vertShader, fragShader, 0); // After linking, shader objects can be deleted.
        
        // Retrieve linked uniform locations.
        uniforms[UNIFORM_MODELVIEW_PROJECTION_MATRIX] = glGetUniformLocation(program, "modelViewProjectionMatrix");
        uniforms[UNIFORM_COLOR] = glGetUniformLocation(program, "color");
    }

    //
    // Setup for drawing video frame.
    //
    glViewport(gViewport[0], gViewport[1], gViewport[2], gViewport[3]);
    
    if (state == FLOW_STATE_WELCOME || state == FLOW_STATE_DONE || state == FLOW_STATE_CALIBRATING) {
        
        // Display the current frame
        vv->draw(vs);
        
    } else if (state == FLOW_STATE_CAPTURING) {
        
        // Grab a lock while we're using the data to prevent it being changed underneath us.
        int cornerFoundAllFlag;
        int cornerCount;
        CvPoint2D32f *corners;
        ARUint8 *videoFrame;
        gCalibration->cornerFinderResultsLockAndFetch(&cornerFoundAllFlag, &cornerCount, &corners, &videoFrame);
        
        // Display the current frame.
        if (videoFrame) arglPixelBufferDataUpload(gArglSettingsCornerFinderImage, videoFrame);
        arglDispImage(gArglSettingsCornerFinderImage, NULL);
        
        //
        // Setup for drawing on top of video frame, in video pixel coordinates.
        //
        mtxLoadIdentityf(p);
        if (vv->rotate90()) mtxRotatef(p, 90.0f, 0.0f, 0.0f, -1.0f);
        if (vv->flipV()) {
            bottom = (float)vs->getVideoHeight();
            top = 0.0f;
        } else {
            bottom = 0.0f;
            top = (float)vs->getVideoHeight();
        }
        if (vv->flipH()) {
            left = (float)vs->getVideoWidth();
            right = 0.0f;
        } else {
            left = 0.0f;
            right = (float)vs->getVideoWidth();
        }
        mtxOrthof(p, left, right, bottom, top, -1.0f, 1.0f);
        mtxLoadIdentityf(m);
        glStateCacheDisableDepthTest();
        glStateCacheDisableBlend();
        
        // Draw the crosses marking the corner positions.
        float fontSizeScaled = FONT_SIZE * (float)vs->getVideoHeight()/(float)(gViewport[(gDisplayOrientation % 2) == 1 ? 3 : 2]);
//        EdenGLFontSetSize(fontSizeScaled);
        vertexCount = cornerCount*4;
        if (vertexCount > 0) {
            arMalloc(vertices, GLfloat, vertexCount*2); // 2 coords per vertex.
            for (i = 0; i < cornerCount; i++) {
                vertices[i*8    ] = corners[i].x - 5.0f;
                vertices[i*8 + 1] = vs->getVideoHeight() - corners[i].y - 5.0f;
                vertices[i*8 + 2] = corners[i].x + 5.0f;
                vertices[i*8 + 3] = vs->getVideoHeight() - corners[i].y + 5.0f;
                vertices[i*8 + 4] = corners[i].x - 5.0f;
                vertices[i*8 + 5] = vs->getVideoHeight() - corners[i].y + 5.0f;
                vertices[i*8 + 6] = corners[i].x + 5.0f;
                vertices[i*8 + 7] = vs->getVideoHeight() - corners[i].y - 5.0f;
                
                unsigned char buf[12]; // 10 digits in INT32_MAX, plus sign, plus null.
                sprintf((char *)buf, "%d\n", i);
                
                GLfloat m0[16];
                mtxLoadMatrixf(m0, m);
                mtxTranslatef(m0, corners[i].x, vs->getVideoHeight() - corners[i].y, 0.0f);
                mtxRotatef(m0, (float)(gDisplayOrientation - 1) * -90.0f, 0.0f, 0.0f, 1.0f); // Orient the text to the user.
//                EdenGLFontDrawLine(0, buf, 0.0f, 0.0f, H_OFFSET_VIEW_LEFT_EDGE_TO_TEXT_LEFT_EDGE, V_OFFSET_VIEW_BOTTOM_TO_TEXT_BASELINE); // These alignment modes don't require setting of EdenGLFontSetViewSize().
            }
        }
//        EdenGLFontSetSize(FONT_SIZE);
        
        gCalibration->cornerFinderResultsUnlock();
        
        if (vertexCount > 0) {
            glUseProgram(program);
            GLfloat colorRed[4] = {1.0f, 0.0f, 0.0f, 1.0f};
            GLfloat colorGreen[4] = {0.0f, 1.0f, 0.0f, 1.0f};
            GLfloat mvp[16];
            mtxLoadMatrixf(mvp, p);
            mtxMultMatrixf(mvp, m);
            glUniformMatrix4fv(uniforms[UNIFORM_MODELVIEW_PROJECTION_MATRIX], 1, GL_FALSE, mvp);
            glUniform4fv(uniforms[UNIFORM_COLOR], 1, cornerFoundAllFlag ? colorRed : colorGreen);
            
            glVertexAttribPointer(ATTRIBUTE_VERTEX, 2, GL_FLOAT, GL_FALSE, 0, vertices);
            glEnableVertexAttribArray(ATTRIBUTE_VERTEX);

            glLineWidth(2.0f);
            glDrawArrays(GL_LINES, 0, vertexCount);
            free(vertices);
        }
    }
    
    //
    // Setup for drawing on top of video frame, in viewPort coordinates.
    //
#if 0
    mtxLoadIdentityf(p);
    bottom = 0.0f;
    top = (float)(viewPort[viewPortIndexHeight]);
    left = 0.0f;
    right = (float)(viewPort[viewPortIndexWidth]);
    mtxOrthof(p, left, right, bottom, top, -1.0f, 1.0f);
    mtxLoadIdentityf(m);
    
    EdenGLFontSetViewSize(right, top);
    EdenMessageSetViewSize(right, top, gDisplayDPI);
#endif
    
    //
    // Setup for drawing on screen, with correct orientation for user.
    //
    glViewport(0, 0, contextWidth, contextHeight);
    mtxLoadIdentityf(p);
    bottom = 0.0f;
    top = (float)contextHeight;
    left = 0.0f;
    right = (float)contextWidth;
    mtxOrthof(p, left, right, bottom, top, -1.0f, 1.0f);
    mtxLoadIdentityf(m);
    
//    EdenGLFontSetViewSize(right, top);
//    EdenMessageSetViewSize(right, top);
//    EdenMessageSetBoxParams(600.0f, 20.0f);
//    float statusBarHeight = EdenGLFontGetHeight() + 4.0f; // 2 pixels above, 2 below.
  
#if 0
    // Draw status bar with centred status message.
    if (statusBarMessage[0]) {
        drawBackground(right, statusBarHeight, 0.0f, 0.0f, false);
        glStateCacheDisableBlend();
        glColor4ub(255, 255, 255, 255);
        EdenGLFontDrawLine(0, statusBarMessage, 0.0f, 2.0f, H_OFFSET_VIEW_CENTER_TO_TEXT_CENTER, V_OFFSET_VIEW_BOTTOM_TO_TEXT_BASELINE);
    }
    
    // If background tasks are proceeding, draw a status box.
    char uploadStatus[UPLOAD_STATUS_BUFFER_LEN];
    int status = fileUploaderStatusGet(fileUploadHandle, uploadStatus, &time);
    if (status) {
        const int squareSize = (int)(16.0f * (float)gDisplayDPI / 160.f) ;
        float x, y, w, h;
        float textWidth = EdenGLFontGetLineWidth((unsigned char *)uploadStatus);
        w = textWidth + 3*squareSize + 2*4.0f /*text margin*/ + 2*4.0f /* box margin */;
        h = MAX(FONT_SIZE, 3*squareSize) + 2*4.0f /* box margin */;
        x = right - (w + 2.0f);
        y = statusBarHeight + 2.0f;
        drawBackground(w, h, x, y, true);
        if (status == 1) drawBusyIndicator((int)(x + 4.0f + 1.5f*squareSize), (int)(y + 4.0f + 1.5f*squareSize), squareSize, &time);
//        EdenGLFontDrawLine(0, (unsigned char *)uploadStatus, x + 4.0f + 3*squareSize, y + (h - FONT_SIZE)/2.0f, H_OFFSET_VIEW_LEFT_EDGE_TO_TEXT_LEFT_EDGE, V_OFFSET_VIEW_BOTTOM_TO_TEXT_BASELINE);
    }
#endif
    
    // If a message should be onscreen, draw it.
//    if (gEdenMessageDrawRequired) EdenMessageDraw(0);
}

- (void) drawCleanupGLES2
{
    if (program) {
        glDeleteProgram(program);
    }
}

// Save parameters file and index file with info about it, then signal thread that it's ready for upload.
- (void) saveParam2:(const ARParam *)param err_min:(ARdouble)err_min err_avg:(ARdouble)err_avg err_max:(ARdouble)err_max
{
    int i;
#define SAVEPARAM_PATHNAME_LEN MAXPATHLEN
    char indexPathname[SAVEPARAM_PATHNAME_LEN];
    char paramPathname[SAVEPARAM_PATHNAME_LEN];
    char indexUploadPathname[SAVEPARAM_PATHNAME_LEN];
    
    // Get the current time. It will be used for file IDs, plus a timestamp for the parameters file.
    time_t ourClock = time(NULL);
    if (ourClock == (time_t)-1) {
        ARLOGe("Error reading time and date.\n");
        return;
    }
    //struct tm *timeptr = localtime(&ourClock);
    struct tm *timeptr = gmtime(&ourClock);
    if (!timeptr) {
        ARLOGe("Error converting time and date to UTC.\n");
        return;
    }
    int ID = timeptr->tm_hour*10000 + timeptr->tm_min*100 + timeptr->tm_sec;
    
    // Save the parameter file.
    snprintf(paramPathname, SAVEPARAM_PATHNAME_LEN, "%s/%s/%06d-camera_para.dat", arUtilGetResourcesDirectoryPath(AR_UTIL_RESOURCES_DIRECTORY_BEHAVIOR_USE_APP_CACHE_DIR), QUEUE_DIR, ID);
    
    //if (arParamSave(strcat(strcat(docsPath,"/"),paramPathname), 1, param) < 0) {
    if (arParamSave(paramPathname, 1, param) < 0) {
        
        ARLOGe("Error writing camera_para.dat file.\n");
        
    } else {
        
        //
        // Write an upload index file with the data for the server database entry.
        //
        
        bool goodWrite = true;
        
        // Open the file.
        snprintf(indexPathname, SAVEPARAM_PATHNAME_LEN, "%s/%s/%06d-index", arUtilGetResourcesDirectoryPath(AR_UTIL_RESOURCES_DIRECTORY_BEHAVIOR_USE_APP_CACHE_DIR), QUEUE_DIR, ID);
        FILE *fp;
        if (!(fp = fopen(indexPathname, "wb"))) {
            ARLOGe("Error opening upload index file '%s'.\n", indexPathname);
            goodWrite = false;
        }
        
        // File name.
        if (goodWrite) fprintf(fp, "file,%s\n", paramPathname);
        
        // UTC date and time, in format "1999-12-31 23:59:59 UTC".
        if (goodWrite) {
            char timestamp[26+8] = "";
            if (!strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S %z", timeptr)) {
                ARLOGe("Error formatting time and date.\n");
                goodWrite = false;
            } else {
                fprintf(fp, "timestamp,%s\n", timestamp);
            }
        }
        
        // OS: name/arch/version.
        if (goodWrite) {
            char *os_name = arUtilGetOSName();
            char *os_arch = arUtilGetCPUName();
            char *os_version = arUtilGetOSVersion();
            fprintf(fp, "os_name,%s\nos_arch,%s\nos_version,%s\n", os_name, os_arch, os_version);
            free(os_name);
            free(os_arch);
            free(os_version);
        }
        
        // Camera identifier.
        if (goodWrite) {
            char *device_id = NULL;
            AR2VideoParamT *vid = vs->getAR2VideoParam();
            if (ar2VideoGetParams(vid, AR_VIDEO_PARAM_DEVICEID, &device_id) < 0 || !device_id) {
                ARLOGe("Error fetching camera device identification.\n");
                goodWrite = false;
            } else {
                fprintf(fp, "device_id,%s\n", device_id);
                free(device_id);
            }
        }
        
        // Focal length in metres.
        if (goodWrite) {
            char *focal_length = NULL;
            AR2VideoParamT *vid = vs->getAR2VideoParam();
            if (vid->module == AR_VIDEO_MODULE_AVFOUNDATION) {
                int focalPreset;
                ar2VideoGetParami(vid, AR_VIDEO_PARAM_AVFOUNDATION_FOCUS_PRESET, &focalPreset);
                switch (focalPreset) {
                    case AR_VIDEO_AVFOUNDATION_FOCUS_MACRO:
                        focal_length = strdup("0.01");
                        break;
                    case AR_VIDEO_AVFOUNDATION_FOCUS_0_3M:
                        focal_length = strdup("0.3");
                        break;
                    case AR_VIDEO_AVFOUNDATION_FOCUS_1_0M:
                        focal_length = strdup("1.0");
                        break;
                    case AR_VIDEO_AVFOUNDATION_FOCUS_INF:
                        focal_length = strdup("1000000.0");
                        break;
                    default:
                        break;
                }
            }
            if (!focal_length) {
                // Not known at present, so just send 0.000.
                focal_length = strdup("0.000");
            }
            fprintf(fp, "focal_length,%s\n", focal_length);
            free(focal_length);
        }
        
        // Camera index.
        if (goodWrite) {
            char camera_index[12]; // 10 digits in INT32_MAX, plus sign, plus null.
            snprintf(camera_index, 12, "%d", 0); // Always zero for desktop platforms.
            fprintf(fp, "camera_index,%s\n", camera_index);
        }
        
        // Front or rear facing.
        if (goodWrite) {
            char camera_face[6]; // "front" or "rear", plus null.
            snprintf(camera_face, 6, "%s", (gCameraIsFrontFacing ? "front" : "rear"));
            fprintf(fp, "camera_face,%s\n", camera_face);
        }
        
        // Camera dimensions.
        if (goodWrite) {
            char camera_width[12]; // 10 digits in INT32_MAX, plus sign, plus null.
            char camera_height[12]; // 10 digits in INT32_MAX, plus sign, plus null.
            snprintf(camera_width, 12, "%d", vs->getVideoWidth());
            snprintf(camera_height, 12, "%d", vs->getVideoHeight());
            fprintf(fp, "camera_width,%s\n", camera_width);
            fprintf(fp, "camera_height,%s\n", camera_height);
        }
        
        // Calibration error.
        if (goodWrite) {
            char err_min_ascii[12];
            char err_avg_ascii[12];
            char err_max_ascii[12];
            snprintf(err_min_ascii, 12, "%f", err_min);
            snprintf(err_avg_ascii, 12, "%f", err_avg);
            snprintf(err_max_ascii, 12, "%f", err_max);
            fprintf(fp, "err_min,%s\n", err_min_ascii);
            fprintf(fp, "err_avg,%s\n", err_avg_ascii);
            fprintf(fp, "err_max,%s\n", err_max_ascii);
        }
        
        // IP address will be derived from connect.
        
        // Hash the shared secret.
        if (goodWrite) {
            char ss[] = CALIBRATION_SERVER_AUTHENTICATION_TOKEN_DEFAULT;
            unsigned char ss_md5[MD5_DIGEST_LENGTH];
            char ss_ascii[MD5_DIGEST_LENGTH*2 + 1]; // space for null terminator.
            if (!MD5((unsigned char *)ss, (MD5_COUNT_t)strlen(ss), ss_md5)) {
                ARLOGe("Error calculating md5.\n");
                goodWrite = false;
            } else {
                for (i = 0; i < MD5_DIGEST_LENGTH; i++) snprintf(&(ss_ascii[i*2]), 3, "%.2hhx", ss_md5[i]);
                fprintf(fp, "ss,%s\n", ss_ascii);
            }
        }
        
        // Done writing index file.
        fclose(fp);
        
        if (goodWrite) {
            // Rename the file with QUEUE_INDEX_FILE_EXTENSION file extension so it's picked up in uploader.
            snprintf(indexUploadPathname, SAVEPARAM_PATHNAME_LEN, "%s." QUEUE_INDEX_FILE_EXTENSION, indexPathname);
            if (rename(indexPathname, indexUploadPathname) < 0) {
                ARLOGe("Error renaming temporary file '%s'.\n", indexPathname);
                goodWrite = false;
            } else {
                // Kick off an upload handling cycle.
                fileUploaderTickle(fileUploadHandle);
            }
        }
        
        if (!goodWrite) {
            // Delete the index and param files.
            if (remove(indexPathname) < 0) {
                ARLOGe("Error removing temporary file '%s'.\n", indexPathname);
                ARLOGperror(NULL);
            }
            if (remove(paramPathname) < 0) {
                ARLOGe("Error removing temporary file '%s'.\n", paramPathname);
                ARLOGperror(NULL);
            }
        }
    }
}

- (IBAction)handleBackButton:(id)sender {
    flowHandleEvent(EVENT_BACK_BUTTON);
}

- (IBAction)handleAddButton:(id)sender {
    flowHandleEvent(EVENT_TOUCH);
}

- (IBAction)handleMenuButton:(id)sender {
}
@end

// Save parameters file and index file with info about it, then signal thread that it's ready for upload.
static void saveParam(const ARParam *param, ARdouble err_min, ARdouble err_avg, ARdouble err_max, void *userdata)
{
    if (userdata) {
        ARViewController *vc = (__bridge ARViewController *)userdata;
        [vc saveParam2:param err_min:err_min err_avg:err_avg err_max:err_max];
    }
}
