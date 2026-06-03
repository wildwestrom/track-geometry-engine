#include <raylib.h>
#include <raymath.h>
#include <lean/lean.h>

// === Lean engine FFI ===========================================================
// These symbols are defined by the compiled Lean modules (TrackGeometry.FFI /
// TrackGeometry.Lib); see TrackGeometry/FFI.lean. The justfile compiles those
// modules to object files and links them in.
void lean_initialize_runtime_module(void);
void lean_io_mark_end_initialization(void);
lean_object *initialize_track__geometry__engine_TrackGeometry_FFI(uint8_t builtin);

lean_object *place(double x, double y);   // record a PI (mouse click); rebuilds the path
lean_object *clearAlignment(void);        // forget all PIs
lean_object *alignmentLength(void);       // total arc-length of the current curve
lean_object *pointAt(double s);           // (x, y) at arc-length s (clamped to the curve)

// Thin C wrappers that unwrap the Lean `IO`/`Float`/`Prod` results.
static void trackGeometryEngineInit(void) {
  lean_initialize_runtime_module();
  lean_object *r = initialize_track__geometry__engine_TrackGeometry_FFI(1);
  if (lean_io_result_is_error(r)) { lean_io_result_show_error(r); }
  lean_dec_ref(r);
  lean_io_mark_end_initialization();
}
static void placeTrack(double x, double y) { lean_dec_ref(place(x, y)); }
static void clearTrack(void) { lean_dec_ref(clearAlignment()); }

static double trackLength(void) {
  lean_object *r = alignmentLength();
  double v = lean_unbox_float(lean_ctor_get(r, 0)); // IO ok -> boxed Float
  lean_dec_ref(r);
  return v;
}
static Vector2 trackPointAt(double s) {
  lean_object *r = pointAt(s);
  lean_object *pr = lean_ctor_get(r, 0);            // IO ok -> Prod Float Float
  double x = lean_unbox_float(lean_ctor_get(pr, 0));
  double y = lean_unbox_float(lean_ctor_get(pr, 1));
  lean_dec_ref(r);
  return (Vector2){(float)x, (float)y};
}
// ===============================================================================

#define DEFAULT_FONT_SIZE 8
#define DARK_MODE

#ifdef DARK_MODE
	#define BG CLITERAL(BLACK)
	#define FG CLITERAL(WHITE)
#else
	#define BG CLITERAL(WHITE)
	#define FG CLITERAL(BLACK)
#endif
#define POINT_COLOR CLITERAL(RED)
#define SECONDARY CLITERAL(GRAY)

#define MAX_PI 512
#define CURVE_SAMPLES 400
// How far you can zoom out.
// smaller = farther out
#define MIN_ZOOM 0.015625f
// How far you can zoom in.
// bigger = further in
#define MAX_ZOOM 64.0f

// Crosshair is drawn in screen space (constant size), but the readout reports
// the world coordinate under the cursor so it stays meaningful while zoomed.
void drawMouse(Camera2D camera) {
  Vector2 mp = GetMousePosition();                       // physical px (SetMouseScale)
  Vector2 wp = GetScreenToWorld2D(mp, camera);           // world, for the label
  // The crosshair draws in screen space, which raylib re-scales by the DPI
  // (screenScale). Divide the physical mouse back to logical so it lands on the
  // cursor instead of being scaled a second time.
  Vector2 dpi = GetWindowScaleDPI();
  Vector2 sp = { mp.x/dpi.x, mp.y/dpi.y };               // logical, for drawing
  const int SIZE = 6;
  // Draw Horizontal
  DrawLine(sp.x - SIZE, sp.y, sp.x + SIZE - 1, sp.y, FG);
  // Draw Vertical
  DrawLine(sp.x, sp.y - SIZE, sp.x, sp.y + SIZE - 1, FG);
  DrawText(TextFormat("(%.1f,%.1f)", wp.x, wp.y),
           sp.x + 1, sp.y + 1, DEFAULT_FONT_SIZE, FG);
}

// Screen-space scale bar (bottom-left), à la a map legend. Picks a "nice" round
// world distance whose on-screen length is close to a target, so the bar grows
// and shrinks with zoom while the label stays a clean 1/2/5 x 10^n value.
void drawScaleBar(Camera2D camera, Vector2 dpi) {
  const float TARGET_PX = 96.0f;           // desired bar length, logical px
  double pxPerWorld = camera.zoom / dpi.x; // logical px per world unit
  double rawWorld = TARGET_PX / pxPerWorld;

  // Round the raw distance down to the nearest 1/2/5 x 10^n.
  double e = floor(log10(rawWorld));
  double f = rawWorld / pow(10.0, e);      // mantissa in [1, 10)
  double nf = f < 1.5 ? 1.0 : f < 3.5 ? 2.0 : f < 7.5 ? 5.0 : 10.0;
  double niceWorld = nf * pow(10.0, e);
  float barPx = (float)(niceWorld * pxPerWorld);

  const char *label = TextFormat("%g u", niceWorld);
  int tw = MeasureText(label, DEFAULT_FONT_SIZE);
  float x1 = GetScreenWidth() - 8.0f;      // bar's right end, near the edge
  float x0 = x1 - barPx;                    // bar's left end
  float y  = GetScreenHeight() - 12.0f;
  const int TICK = 4;

  DrawText(label, x0 - tw - 6.0f, y - DEFAULT_FONT_SIZE / 2.0f,
           DEFAULT_FONT_SIZE, FG);
  DrawLine(x0, y, x1, y, FG);              // bar
  DrawLine(x0, y - TICK, x0, y, FG);       // left end cap
  DrawLine(x1, y - TICK, x1, y, FG);       // right end cap
}

int main(void) {
  trackGeometryEngineInit();

  SetConfigFlags(FLAG_VSYNC_HINT | FLAG_WINDOW_HIGHDPI);
  InitWindow(640, 480, "Track Geometry");
  HideCursor();
  SetTraceLogLevel(LOG_DEBUG);

  Vector2 pis[MAX_PI];   // placed points of intersection, in WORLD coordinates
  int nPI = 0;

  Camera2D camera = { 0 };
  camera.zoom = 1.0f;

  // Cached polyline of the smooth alignment. The geometry only changes when a PI
  // is placed or cleared, so we resample the (expensive) Lean curve into this
  // buffer on change and just redraw it every frame. Sampling every frame instead
  // — 400 FFI roundtrips, each recomputing the whole path length — is what tanked
  // the FPS as PIs piled up.
  Vector2 curve[CURVE_SAMPLES + 1];
  int nCurve = 0;        // valid points in `curve` (0 or CURVE_SAMPLES + 1)
  bool dirty = false;    // geometry changed; curve needs rebuilding

  while (!WindowShouldClose()) {
    Vector2 dpi = GetWindowScaleDPI();
    SetMouseScale(dpi.x, dpi.y);

    // --- input ---------------------------------------------------------------
    float wheel = GetMouseWheelMove();
    if (wheel != 0) {
      Vector2 mouseWorld = GetScreenToWorld2D(GetMousePosition(), camera);
      camera.offset = GetMousePosition();
      camera.target = mouseWorld;
      camera.zoom =
          Clamp(expf(logf(camera.zoom) + 0.2f * wheel), MIN_ZOOM, MAX_ZOOM);
    }

    // Middle-drag to pan.
    if (IsMouseButtonDown(MOUSE_BUTTON_MIDDLE)) {
      Vector2 delta = Vector2Scale(GetMouseDelta(), -1.0f / camera.zoom);
      camera.target = Vector2Add(camera.target, delta);
    }

    if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT) && nPI < MAX_PI) {
      Vector2 m = GetScreenToWorld2D(GetMousePosition(), camera);
      pis[nPI++] = m;
      placeTrack(m.x, m.y);
      dirty = true;
    }
    if (IsMouseButtonPressed(MOUSE_BUTTON_RIGHT) || IsKeyPressed(KEY_C)) {
      nPI = 0;
      clearTrack();
      dirty = true;
    }

    // --- rebuild cached curve (only when the PIs changed) --------------------
    if (dirty) {
      nCurve = 0;
      if (nPI >= 2) {
        double L = trackLength();
        if (L > 0.0) {
          for (int i = 0; i <= CURVE_SAMPLES; i++)
            curve[nCurve++] = trackPointAt(L * (double)i / (double)CURVE_SAMPLES);
        }
      }
      dirty = false;
    }

    // --- draw ----------------------------------------------------------------
    BeginDrawing(); ClearBackground(BG);

    BeginMode2D(camera);
      // Tangent polyline through the raw PIs (faint).
      for (int i = 1; i < nPI; i++) DrawLineV(pis[i - 1], pis[i], SECONDARY);

      // The smooth alignment: straights joined by auto-radius circular arcs.
      // Drawn from the cached polyline (resampled only when the PIs change).
      for (int i = 1; i < nCurve; i++) DrawLineV(curve[i - 1], curve[i], FG);

      // PI markers.
      for (int i = 0; i < nPI; i++)
        DrawCircleV(pis[i], 4.0f / camera.zoom, POINT_COLOR);
    EndMode2D();

    // Screen-space HUD (kept out of the camera so it never scales).
	  DrawFPS(0, 0);
    DrawText(TextFormat("DPI Scale: %.1f %.1f   zoom: %.2fx", dpi.x, dpi.y, camera.zoom),
             0, 16, DEFAULT_FONT_SIZE, FG);
    DrawText("left-click: place PI    right-click / C: clear    "
             "scroll: zoom    middle-drag: pan",
             0, 28, DEFAULT_FONT_SIZE, FG);

    drawScaleBar(camera, dpi);
    drawMouse(camera);
    EndDrawing();
  }

  CloseWindow();
}
