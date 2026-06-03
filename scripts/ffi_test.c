// Headless test of the Lean FFI: place() / pointAt() / alignmentLength().
// Build (from repo root):
//   leanc -c .lake/build/ir/TrackGeometry/Lib.c -o /tmp/Lib.o
//   leanc -c .lake/build/ir/TrackGeometry/FFI.c -o /tmp/FFI.o
//   leanc scripts/ffi_test.c /tmp/Lib.o /tmp/FFI.o -lm -o /tmp/ffi_test
#include <stdio.h>
#include <lean/lean.h>

// Lean runtime + module initializer (declared here; defined in libleanshared / FFI.o).
void lean_initialize_runtime_module(void);
void lean_io_mark_end_initialization(void);
lean_object *initialize_track__geometry__engine_TrackGeometry_FFI(uint8_t builtin);

// Our exported engine API.
lean_object *place(double x, double y);
lean_object *clearAlignment(void);
lean_object *alignmentLength(void);
lean_object *pointAt(double s);

int main(void) {
  lean_initialize_runtime_module();
  lean_object *ir = initialize_track__geometry__engine_TrackGeometry_FFI(1);
  if (lean_io_result_is_error(ir)) { lean_io_result_show_error(ir); return 1; }
  lean_dec_ref(ir);
  lean_io_mark_end_initialization();

  // An L: (0,0) -> (100,0) -> (100,100). The interior corner gets rounded.
  lean_dec_ref(place(0.0, 0.0));
  lean_dec_ref(place(100.0, 0.0));
  lean_dec_ref(place(100.0, 100.0));

  lean_object *lr = alignmentLength();
  double L = lean_unbox_float(lean_ctor_get(lr, 0));
  lean_dec_ref(lr);
  printf("alignment length = %.4f\n", L);

  for (int i = 0; i <= 10; i++) {
    double s = L * i / 10.0;
    lean_object *r = pointAt(s);
    lean_object *prod = lean_ctor_get(r, 0);
    double x = lean_unbox_float(lean_ctor_get(prod, 0));
    double y = lean_unbox_float(lean_ctor_get(prod, 1));
    lean_dec_ref(r);
    printf("s=%8.3f -> (%8.3f, %8.3f)\n", s, x, y);
  }
  return 0;
}
