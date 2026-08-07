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

#include <isa.h>

/* We use the POSIX regex functions to process regular expressions.
 * Type 'man regex' for more information about POSIX regex functions.
 */
#include <regex.h>

enum {
  TK_NOTYPE = 256,
  TK_EQ,
  TK_NEQ,
  TK_AND,
  TK_NUM,
  TK_REG,

};

static struct rule {
  const char *regex;
  int token_type;
} rules[] = {

  /* TODO: Add more rules.
   * Pay attention to the precedence level of different rules.
   */

  {" +", TK_NOTYPE},
  {"0[xX][0-9a-fA-F]+[uU]?", TK_NUM},
  {"[0-9]+[uU]?", TK_NUM},
  {"\\$[a-zA-Z0-9]+", TK_REG},
  {"==", TK_EQ},
  {"!=", TK_NEQ},
  {"&&", TK_AND},
  {"\\+", '+'},
  {"\\-", '-'},
  {"\\*", '*'},
  {"/", '/'},
  {"\\(", '('},
  {"\\)", ')'},

};

#define NR_REGEX ARRLEN(rules)

static regex_t re[NR_REGEX] = {};

/* Rules are used for many times.
 * Therefore we compile them only once before any usage.
 */
void init_regex() {
  int i;
  char error_msg[128];
  int ret;

  for (i = 0; i < NR_REGEX; i ++) {
    ret = regcomp(&re[i], rules[i].regex, REG_EXTENDED);
    if (ret != 0) {
      regerror(ret, &re[i], error_msg, 128);
      panic("regex compilation failed: %s\n%s", error_msg, rules[i].regex);
    }
  }
}

typedef struct token {
  int type;
  char str[32];
} Token;

static Token tokens[65536] = {};
static int nr_token = 0;

static bool make_token(char *e) {
  int position = 0;
  int i;
  regmatch_t pmatch;

  nr_token = 0;

  while (e[position] != '\0') {
    /* Try all rules one by one. */
    for (i = 0; i < NR_REGEX; i ++) {
      if (regexec(&re[i], e + position, 1, &pmatch, 0) == 0 && pmatch.rm_so == 0) {
        char *substr_start = e + position;
        int substr_len = pmatch.rm_eo;

        Log("match rules[%d] = \"%s\" at position %d with len %d: %.*s",
            i, rules[i].regex, position, substr_len, substr_len, substr_start);

        position += substr_len;

        switch (rules[i].token_type) {
          case TK_NOTYPE:
            break;
          default:
            Assert(nr_token < ARRLEN(tokens), "too many tokens");
            tokens[nr_token].type = rules[i].token_type;
            if (rules[i].token_type == TK_NUM || rules[i].token_type == TK_REG) {
              Assert(substr_len < sizeof(tokens[nr_token].str), "token is too long");
              memcpy(tokens[nr_token].str, substr_start, substr_len);
              tokens[nr_token].str[substr_len] = '\0';
            }
            nr_token++;
            break;
        }

        break;
      }
    }

    if (i == NR_REGEX) {
      printf("no match at position %d\n%s\n%*.s^\n", position, e, position, "");
      return false;
    }
  }

  return true;
}

static bool check_parentheses(int p, int q) {
  if (p > q || tokens[p].type != '(' || tokens[q].type != ')') {
    return false;
  }

  int depth = 0;
  for (int i = p; i <= q; i++) {
    if (tokens[i].type == '(') {
      depth++;
    }
    else if (tokens[i].type == ')') {
      depth--;
      if (depth < 0 || (depth == 0 && i != q)) {
        return false;
      }
    }
  }

  return depth == 0;
}

static int precedence(int type) {
  switch (type) {
    case TK_AND: return 0;
    case TK_EQ:
    case TK_NEQ: return 1;
    case '+':
    case '-': return 2;
    case '*':
    case '/': return 3;
    default: return -1;
  }
}

static word_t eval(int p, int q, bool *success) {
  if (p > q) {
    *success = false;
    return 0;
  }

  if (p == q) {
    if (tokens[p].type == TK_NUM) {
      return (word_t)strtoull(tokens[p].str, NULL, 0);
    }
    if (tokens[p].type == TK_REG) {
      return isa_reg_str2val(tokens[p].str, success);
    }
    *success = false;
    return 0;
  }

  if (check_parentheses(p, q)) {
    return eval(p + 1, q - 1, success);
  }

  int op = -1;
  int min_priority = 100;
  int depth = 0;
  for (int i = p; i <= q; i++) {
    if (tokens[i].type == '(') {
      depth++;
      continue;
    }
    if (tokens[i].type == ')') {
      depth--;
      if (depth < 0) {
        *success = false;
        return 0;
      }
      continue;
    }
    if (depth != 0) {
      continue;
    }

    int priority = precedence(tokens[i].type);
    if (priority >= 0 && priority <= min_priority) {
      min_priority = priority;
      op = i;
    }
  }

  if (depth != 0 || op < 0) {
    *success = false;
    return 0;
  }

  word_t val1 = eval(p, op - 1, success);
  if (!*success) {
    return 0;
  }
  word_t val2 = eval(op + 1, q, success);
  if (!*success) {
    return 0;
  }

  switch (tokens[op].type) {
    case '+': return val1 + val2;
    case '-': return val1 - val2;
    case '*': return val1 * val2;
    case '/':
      if (val2 == 0) {
        *success = false;
        return 0;
      }
      return val1 / val2;
    case TK_EQ: return val1 == val2;
    case TK_NEQ: return val1 != val2;
    case TK_AND: return val1 && val2;
    default:
      *success = false;
      return 0;
  }
}


word_t expr(char *e, bool *success) {
  if (!make_token(e)) {
    *success = false;
    return 0;
  }

  if (nr_token == 0) {
    *success = false;
    return 0;
  }

  *success = true;
  return eval(0, nr_token - 1, success);
}
