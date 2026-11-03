#version 430 core

layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    uniform float iTimeDelta;
    uniform float iFrameRate;
    uniform int   iFrame;
    uniform float iChannelTime[4];
    uniform vec3  iChannelResolution[4];
    uniform vec4  iMouse;
    uniform vec4  iDate;
    uniform float iSampleRate;
    uniform vec4  iCurrentCursor;
    uniform vec4  iPreviousCursor;
    uniform vec4  iCurrentCursorColor;
    uniform vec4  iPreviousCursorColor;
    uniform int   iCurrentCursorStyle;
    uniform int   iPreviousCursorStyle;
    uniform int   iCursorVisible;
    uniform float iTimeCursorChange;
    uniform float iTimeFocus;
    uniform int iFocus;
    uniform vec3  iPalette[256];
    uniform vec3  iBackgroundColor;
    uniform vec3  iForegroundColor;
    uniform vec3  iCursorColor;
    uniform vec3  iCursorText;
    uniform vec3  iSelectionForegroundColor;
    uniform vec3  iSelectionBackgroundColor;
    // This fork. A move is the cursor changing CELL (not a bar/block width
    // change), and never while a scroll animates: iCursorMoveFrom/To are
    // the rects either side of it. A mode change is the cursor's style or
    // colour changing. A pulse is OSC 777;cursor-pulse. Times are iTime
    // seconds; -1000 when it never happened.
    uniform vec4  iCursorMoveFrom;
    uniform vec4  iCursorMoveTo;
    uniform float iTimeCursorMove;
    uniform float iTimeCursorMode;
    uniform float iTimeCursorPulse;
    // The last CURSOR_FX_EVENTS mode changes and pulses (a ring, oldest
    // overwritten first) so effects can overlap. Per event: iCursorFxEvent =
    // (start iTime, cursor style, kind 0=mode 1=pulse 2=boom, boom power); the cursor colour
    // and rect when it happened. Unused slots have start -1000.
    uniform vec4  iCursorFxEvent[6];
    uniform vec4  iCursorFxEventColor[6];
    uniform vec4  iCursorFxEventRect[6];
};

#define CURSOR_FX_EVENTS 6

#define CURSORSTYLE_BLOCK        0
#define CURSORSTYLE_BLOCK_HOLLOW 1
#define CURSORSTYLE_BAR          2
#define CURSORSTYLE_UNDERLINE    3
#define CURSORSTYLE_LOCK         4

layout(binding = 0) uniform sampler2D iChannel0;

// These are unused currently by Ghostty:
// layout(binding = 1) uniform sampler2D iChannel1;
// layout(binding = 2) uniform sampler2D iChannel2;
// layout(binding = 3) uniform sampler2D iChannel3;

layout(location = 0) in vec4 gl_FragCoord;
layout(location = 0) out vec4 _fragColor;

#define texture2D texture

void mainImage( out vec4 fragColor, in vec2 fragCoord );
void main() { mainImage (_fragColor, gl_FragCoord.xy); }
