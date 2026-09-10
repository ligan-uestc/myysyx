#include <klib.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

/* The format engine below is shared by all output functions: every produced
 * character is handed to an output callback, so that printf()/vprintf()
 * (writing to putch()) and sprintf()/vsprintf() (writing to a buffer) do not
 * duplicate any formatting code. */
typedef void (*out_func)(char ch, void *opaque);

static void __am_out_buf(char ch, void *opaque) {
  char **p = opaque;
  *(*p) ++ = ch;
}

static void __am_out_dev(char ch, void *opaque) {
  (void)opaque;
  putch(ch);
}

/* Emit s[0..n) with the given field width.  `left' selects left alignment. */
static int __am_emit(out_func out, void *opaque, const char *s, int n,
    int width, char pad, bool left) {
  int cnt = 0;
  int n_pad = (width > n ? width - n : 0);
  if (!left && pad == '0' && n > 0 && s[0] == '-') {
    /* keep the sign in front of the zero padding: "%05d", -3 -> "-0003" */
    out('-', opaque); cnt ++;
    s ++; n --;
    n_pad = (width > n + 1 ? width - n - 1 : 0);
  }
  if (!left) {
    for (int i = 0; i < n_pad; i ++) { out(pad, opaque); cnt ++; }
  }
  for (int i = 0; i < n; i ++) { out(s[i], opaque); cnt ++; }
  if (left) {
    for (int i = 0; i < n_pad; i ++) { out(' ', opaque); cnt ++; }
  }
  return cnt;
}

static int __am_emit_num(out_func out, void *opaque, unsigned int val,
    int base, bool upper, bool neg, int width, char pad, bool left) {
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  char buf[32];
  int i = sizeof(buf);
  do {
    buf[-- i] = digits[val % (unsigned int)base];
    val /= (unsigned int)base;
  } while (val != 0);
  if (neg) buf[-- i] = '-';
  return __am_emit(out, opaque, &buf[i], (int)sizeof(buf) - i, width, pad, left);
}

static int __am_kvprintf(out_func out, void *opaque, const char *fmt, va_list ap) {
  int cnt = 0;
  while (*fmt != '\0') {
    char ch = *fmt ++;
    if (ch != '%') { out(ch, opaque); cnt ++; continue; }

    /* flags */
    bool left = false;
    char pad = ' ';
    while (*fmt == '-' || *fmt == '0' || *fmt == '+' || *fmt == ' ') {
      if (*fmt == '-') left = true;
      else if (*fmt == '0') pad = '0';
      fmt ++;
    }
    if (left) pad = ' '; // '-' overrides '0'
    /* field width */
    int width = 0;
    while (*fmt >= '0' && *fmt <= '9') { width = width * 10 + (*fmt - '0'); fmt ++; }
    /* precision (only used by %s here) */
    int prec = -1;
    if (*fmt == '.') {
      fmt ++;
      prec = 0;
      while (*fmt >= '0' && *fmt <= '9') { prec = prec * 10 + (*fmt - '0'); fmt ++; }
    }
    /* length modifiers: in ilp32 int/long/size_t are all 32-bit */
    while (*fmt == 'l' || *fmt == 'h' || *fmt == 'z' || *fmt == 'j') fmt ++;

    ch = *fmt ++;
    switch (ch) {
      case 'd': case 'i': {
        int v = va_arg(ap, int);
        unsigned int u = (unsigned int)v;
        bool neg = false;
        if (v < 0) { neg = true; u = 0u - u; }
        cnt += __am_emit_num(out, opaque, u, 10, false, neg, width, pad, left);
        break;
      }
      case 'u':
        cnt += __am_emit_num(out, opaque, va_arg(ap, unsigned int), 10, false, false, width, pad, left);
        break;
      case 'x':
        cnt += __am_emit_num(out, opaque, va_arg(ap, unsigned int), 16, false, false, width, pad, left);
        break;
      case 'X':
        cnt += __am_emit_num(out, opaque, va_arg(ap, unsigned int), 16, true, false, width, pad, left);
        break;
      case 'p': {
        uintptr_t v = (uintptr_t)va_arg(ap, void *);
        out('0', opaque); out('x', opaque); cnt += 2;
        cnt += __am_emit_num(out, opaque, (unsigned int)v, 16, false, false,
            (width > 2 ? width - 2 : 0), '0', false);
        break;
      }
      case 'c':
        out((char)va_arg(ap, int), opaque); cnt ++;
        break;
      case 's': {
        const char *s = va_arg(ap, const char *);
        if (s == NULL) s = "(null)";
        int n = 0;
        while (s[n] != '\0' && (prec < 0 || n < prec)) n ++;
        cnt += __am_emit(out, opaque, s, n, width, ' ', left);
        break;
      }
      case '%':
        out('%', opaque); cnt ++;
        break;
      case '\0': /* a lone '%' at the end of the format string */
        out('%', opaque); cnt ++;
        fmt --;
        break;
      default:
        out('%', opaque); out(ch, opaque); cnt += 2;
        break;
    }
  }
  return cnt;
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  char *p = out;
  int ret = __am_kvprintf(__am_out_buf, &p, fmt, ap);
  *p = '\0';
  return ret;
}

int sprintf(char *out, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int ret = vsprintf(out, fmt, ap);
  va_end(ap);
  return ret;
}

int vprintf(const char *fmt, va_list ap) {
  return __am_kvprintf(__am_out_dev, NULL, fmt, ap);
}

int printf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int ret = vprintf(fmt, ap);
  va_end(ap);
  return ret;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

int __am_vsscanf_internal(const char *str, const char **end_pstr, const char *fmt, va_list ap) {
  const char *pstr = str;
  const char *pfmt = fmt;
  int item = -1;
  while (*pfmt) {
    char ch = *pfmt ++;
    if (isspace(ch)) {
      for (ch = *pfmt; isspace(ch); ch = *(++ pfmt));
      for (ch = *pstr; isspace(ch); ch = *(++ pstr));
      item ++;
      continue;
    }
    switch (ch) {
      case '%': break;
      default:
        if (*pstr == ch) { // match
          pstr ++;
          item ++;
          continue;
        }
        goto end; // fail
    }

    char *p;
    ch = *pfmt ++;
    switch (ch) {
      // conversion specifier
      case 'd':
        *(va_arg(ap, int *)) = strtol(pstr, &p, 10);
        if (p == pstr) goto end; // fail
        pstr = p;
        item ++;
        break;

      case 'c':
        *(va_arg(ap, char *)) = *pstr ++;
        item ++;
        break;

      default:
        printf("Unsupported conversion specifier '%c'\n", ch);
        assert(0);
    }
  }

end:
  if (end_pstr) {
    *end_pstr = pstr;
  }
  return item;
}

int vsscanf(const char *str, const char *fmt, va_list ap) {
  return __am_vsscanf_internal(str, NULL, fmt, ap);
}

int sscanf(const char *str, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsscanf(str, fmt, ap);
  va_end(ap);
  return r;
}

int __isoc99_sscanf(const char *str, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  int r = vsscanf(str, fmt, ap);
  va_end(ap);
  return r;
}

#endif
