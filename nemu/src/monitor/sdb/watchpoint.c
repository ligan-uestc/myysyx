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

#include "sdb.h"

#define NR_WP 32
#define WP_EXPR_LEN 128

typedef struct watchpoint {
  int NO;
  struct watchpoint *next;
  char expression[WP_EXPR_LEN];
  word_t old_value;

} WP;

static WP wp_pool[NR_WP] = {};
static WP *head = NULL, *free_ = NULL;

void init_wp_pool() {
  int i;
  for (i = 0; i < NR_WP; i ++) {
    wp_pool[i].NO = i;
    wp_pool[i].next = (i == NR_WP - 1 ? NULL : &wp_pool[i + 1]);
  }

  head = NULL;
  free_ = wp_pool;
}

static WP *new_wp(void) {
  Assert(free_ != NULL, "No free watchpoint");

  WP *wp = free_;
  free_ = free_->next;
  wp->next = head;
  head = wp;
  return wp;
}

static void free_wp(WP *wp) {
  WP **current = &head;

  while (*current != NULL && *current != wp) {
    current = &(*current)->next;
  }
  Assert(*current == wp, "Watchpoint %d is not in use", wp->NO);

  *current = wp->next;
  wp->next = free_;
  free_ = wp;
}

bool wp_add(const char *expression) {
  bool success = true;
  word_t value = expr((char *)expression, &success);
  if (!success) {
    return false;
  }

  WP *wp = new_wp();
  int length = snprintf(wp->expression, sizeof(wp->expression), "%s", expression);
  Assert(length >= 0 && length < sizeof(wp->expression), "Watchpoint expression is too long");
  wp->old_value = value;

  printf("Watchpoint %d: %s\n", wp->NO, wp->expression);
  return true;
}

bool wp_delete(int number) {
  for (WP *wp = head; wp != NULL; wp = wp->next) {
    if (wp->NO == number) {
      free_wp(wp);
      return true;
    }
  }
  return false;
}

void wp_display(void) {
  printf("Num\tValue\t\tExpression\n");
  for (WP *wp = head; wp != NULL; wp = wp->next) {
    printf("%d\t" FMT_WORD "\t%s\n", wp->NO, wp->old_value, wp->expression);
  }
}

bool check_wp(void) {
  bool triggered = false;

  for (WP *wp = head; wp != NULL; wp = wp->next) {
    bool success = true;
    word_t new_value = expr(wp->expression, &success);
    Assert(success, "Watchpoint %d expression is invalid", wp->NO);

    if (new_value != wp->old_value) {
      printf("Watchpoint %d triggered: %s\n", wp->NO, wp->expression);
      printf("Old value = " FMT_WORD "\n", wp->old_value);
      printf("New value = " FMT_WORD "\n", new_value);
      wp->old_value = new_value;
      triggered = true;
    }
  }

  return triggered;
}
