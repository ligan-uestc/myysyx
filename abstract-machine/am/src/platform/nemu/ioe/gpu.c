#include <am.h>
#include <nemu.h>

#define SYNC_ADDR (VGACTL_ADDR + 4)

void __am_gpu_init() {
}

void __am_gpu_config(AM_GPU_CONFIG_T *cfg) {
  uint32_t screen = inl(VGACTL_ADDR);
  int w = screen >> 16;
  int h = screen & 0xffff;
  *cfg = (AM_GPU_CONFIG_T) {
    .present = true, .has_accel = false,
    .width = w, .height = h,
    .vmemsz = w * h * (int)sizeof(uint32_t)
  };
}

void __am_gpu_fbdraw(AM_GPU_FBDRAW_T *ctl) {
  int x = ctl->x, y = ctl->y, w = ctl->w, h = ctl->h;
  uint32_t *pixels = ctl->pixels;
  uint32_t *fb = (uint32_t *)(uintptr_t)FB_ADDR;
  int screen_w = inl(VGACTL_ADDR) >> 16;
  for (int j = 0; j < h; j ++) {
    for (int i = 0; i < w; i ++) {
      fb[(y + j) * screen_w + (x + i)] = pixels[j * w + i];
    }
  }
  if (ctl->sync) {
    outl(SYNC_ADDR, 1);
  }
}

void __am_gpu_status(AM_GPU_STATUS_T *status) {
  status->ready = true;
}
