/***************************************************************************************
* Copyright (c) 2014-2024 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <assert.h>
#include <string.h>

// this should be enough
static char buf[65536] = {};
static size_t buf_pos = 0;
static char code_buf[65536 + 128] = {};
static char *code_format =
"#include <stdio.h>\n"
"int main() { "
"  unsigned result = %s; "
"  printf(\"%%u\", result); "
"  return 0; "
"}";

static uint32_t choose(uint32_t n) {
  assert(n > 0);
  return (uint32_t)rand() % n;
}

static uint32_t rand_u32() {
  return ((uint32_t)rand() << 17) ^ ((uint32_t)rand() << 2) ^ (uint32_t)rand();
}

static void append_text(const char *text) {
  size_t len = strlen(text);
  assert(buf_pos + len < sizeof(buf));
  memcpy(buf + buf_pos, text, len);
  buf_pos += len;
  buf[buf_pos] = '\0';
}

static void append_char(char c) {
  assert(buf_pos + 1 < sizeof(buf));
  buf[buf_pos++] = c;
  buf[buf_pos] = '\0';
}

static void append_space() {
  if (choose(2) == 0) {
    append_char(' ');
  }
}

static void append_number(uint32_t value) {
  char number[16];
  int len = snprintf(number, sizeof(number), "%u", (unsigned)value);
  assert(len > 0 && (size_t)len < sizeof(number));
  append_text(number);
  append_char('u');
}

static uint32_t gen_expr(int depth) {
  enum { MAX_DEPTH = 6 };

  if (depth >= MAX_DEPTH || choose(3) == 0) {
    uint32_t value = rand_u32();
    append_number(value);
    return value;
  }

  if (choose(2) == 0) {
    append_char('(');
    append_space();
    uint32_t value = gen_expr(depth + 1);
    append_space();
    append_char(')');
    return value;
  }

  append_char('(');
  append_space();
  uint32_t left = gen_expr(depth + 1);
  append_space();
  char op = "+-*/"[choose(4)];
  append_char(op);
  append_space();

  size_t right_start = buf_pos;
  uint32_t right;
  do {
    buf_pos = right_start;
    buf[buf_pos] = '\0';
    right = gen_expr(depth + 1);
  } while (op == '/' && right == 0);

  append_space();
  append_char(')');

  switch (op) {
    case '+': return left + right;
    case '-': return left - right;
    case '*': return left * right;
    default: return left / right;
  }
}

static void gen_rand_expr() {
  buf_pos = 0;
  buf[0] = '\0';
  gen_expr(0);
}

int main(int argc, char *argv[]) {
  int seed = time(0);
  srand(seed);
  int loop = 1;
  if (argc > 1) {
    sscanf(argv[1], "%d", &loop);
  }
  int i;
  for (i = 0; i < loop; i ++) {
    gen_rand_expr();

    sprintf(code_buf, code_format, buf);

    FILE *fp = fopen("/tmp/.code.c", "w");
    assert(fp != NULL);
    fputs(code_buf, fp);
    fclose(fp);

    int ret = system("gcc /tmp/.code.c -o /tmp/.expr");
    if (ret != 0) continue;

    fp = popen("/tmp/.expr", "r");
    assert(fp != NULL);

    unsigned result;
    ret = fscanf(fp, "%u", &result);
    pclose(fp);

    printf("%u %s\n", result, buf);
  }
  return 0;
}
