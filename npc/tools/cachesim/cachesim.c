// ============================================================================
// cachesim —— 简易 cache 模拟器 (B4 讲义 "实现cachesim")
//
// 它只维护 cache 的"元数据", 不保存数据: 对于给定的访存地址序列, cache 的
// 缺失次数与访存内容无关, 因此只要一个 PC 序列 (itrace) 就能统计出 icache 的
// 缺失次数, 完全不需要跑 NPC, 更不需要跑 ysyxSoC —— 这就是设计空间探索能比
// RTL 仿真快几千倍的原因。
//
// 用法:
//   cachesim [OPTION]... TRACE
//     -b BYTES   块大小 (字节, 默认 4)
//     -k N       cache 块总数 (默认 16)
//     -w N       路数 (默认 1 = 直接映射)
//     -p POLICY  替换算法: lru | fifo | random (默认 lru)
//     -c CYCLES  平均缺失代价 (周期), 用于估算 TMT (默认 0, 只统计缺失次数)
//     -f         从标准输入读取
//     -B         输入是二进制 (每 4 字节一个小端 PC)
//     -q         只打印一行结果
//   TRACE 为 "-" 时从标准输入读取; 以 .bz2 结尾时用 bzcat 解压 (popen)。
//
// 输出的最后一行是机器可读的:
//   RESULT accesses=<访问数> hits=<命中数> misses=<缺失数> miss_rate=<缺失率>
//          tmt=<总缺失时间> block=.. blocks=.. ways=.. policy=..
// ============================================================================
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// ---------------------------------------------------------------------------
// cache 参数与元数据
// ---------------------------------------------------------------------------
static int block_bytes = 4;
static int n_blocks    = 16;
static int n_ways      = 1;
static char policy[16] = "lru";

typedef struct {
  uint32_t tag;
  uint8_t  valid;
  uint64_t stamp;   // lru/fifo 的时间戳
} line_t;

static line_t *lines;      // [sets][ways]
static int     n_sets;
static uint64_t clock_stamp;

// 分裂混合: 让 random 替换不依赖 libc rand 的全局状态 (便于复现)
static uint64_t rng_state = 0x12345678u;
static uint32_t rng(void) {
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 7;
  rng_state ^= rng_state << 17;
  return (uint32_t)rng_state;
}

static void cache_init(void) {
  if (n_blocks % n_ways != 0) {
    fprintf(stderr, "cachesim: 块数 %d 不能被路数 %d 整除\n", n_blocks, n_ways);
    exit(1);
  }
  n_sets = n_blocks / n_ways;
  lines = calloc((size_t)n_sets * n_ways, sizeof(line_t));
  if (!lines) { perror("calloc"); exit(1); }
}

// 返回 1 表示命中
static int cache_access(uint32_t addr) {
  uint32_t blk   = addr / (uint32_t)block_bytes;
  uint32_t index = blk % (uint32_t)n_sets;
  uint32_t tag   = blk / (uint32_t)n_sets;
  line_t  *set   = &lines[(size_t)index * n_ways];

  clock_stamp ++;

  // 1) 命中?
  for (int w = 0; w < n_ways; w ++) {
    if (set[w].valid && set[w].tag == tag) {
      if (strcmp(policy, "fifo") != 0) set[w].stamp = clock_stamp;
      return 1;
    }
  }

  // 2) 缺失: 找一个空闲行, 或者按替换算法选一个牺牲者
  int victim = -1;
  for (int w = 0; w < n_ways; w ++) {
    if (!set[w].valid) { victim = w; break; }
  }
  if (victim < 0) {
    if (strcmp(policy, "random") == 0) {
      victim = (int)(rng() % (uint32_t)n_ways);
    } else {
      victim = 0;
      for (int w = 1; w < n_ways; w ++)
        if (set[w].stamp < set[victim].stamp) victim = w;
    }
  }
  set[victim].valid = 1;
  set[victim].tag   = tag;
  set[victim].stamp = clock_stamp;
  return 0;
}

// ---------------------------------------------------------------------------
// 读取 itrace
// ---------------------------------------------------------------------------
static FILE *open_trace(const char *path) {
  if (path == NULL || strcmp(path, "-") == 0) return stdin;
  size_t n = strlen(path);
  if (n > 4 && strcmp(path + n - 4, ".bz2") == 0) {
    char cmd[4096];
    snprintf(cmd, sizeof(cmd), "bzcat '%s'", path);
    FILE *fp = popen(cmd, "r");
    if (!fp) { perror("popen(bzcat)"); exit(1); }
    return fp;
  }
  FILE *fp = fopen(path, "r");
  if (!fp) { perror(path); exit(1); }
  return fp;
}

int main(int argc, char **argv) {
  const char *trace_path = NULL;
  int binary = 0, quiet = 0;
  uint64_t miss_penalty = 0;

  for (int i = 1; i < argc; i ++) {
    if      (strcmp(argv[i], "-b") == 0 && i + 1 < argc) block_bytes = atoi(argv[++i]);
    else if (strcmp(argv[i], "-k") == 0 && i + 1 < argc) n_blocks    = atoi(argv[++i]);
    else if (strcmp(argv[i], "-w") == 0 && i + 1 < argc) n_ways      = atoi(argv[++i]);
    else if (strcmp(argv[i], "-p") == 0 && i + 1 < argc) { snprintf(policy, sizeof(policy), "%s", argv[++i]); }
    else if (strcmp(argv[i], "-c") == 0 && i + 1 < argc) miss_penalty = strtoull(argv[++i], NULL, 0);
    else if (strcmp(argv[i], "-f") == 0) binary = 0;
    else if (strcmp(argv[i], "-B") == 0) binary = 1;
    else if (strcmp(argv[i], "-q") == 0) quiet = 1;
    else if (argv[i][0] != '-')          trace_path = argv[i];
    else { fprintf(stderr, "cachesim: 未知选项 %s\n", argv[i]); return 1; }
  }

  cache_init();
  FILE *fp = open_trace(trace_path);

  uint64_t n_access = 0, n_hit = 0, n_miss = 0;
  uint32_t pc;
  if (binary) {
    while (fread(&pc, sizeof(pc), 1, fp) == 1) {
      n_access ++;
      if (cache_access(pc)) n_hit ++; else n_miss ++;
    }
  } else {
    char buf[256];
    while (fgets(buf, sizeof(buf), fp)) {
      if (sscanf(buf, "%x", &pc) != 1) continue;
      n_access ++;
      if (cache_access(pc)) n_hit ++; else n_miss ++;
    }
  }
  if (fp != stdin) fclose(fp);

  double miss_rate = n_access ? (double)n_miss / (double)n_access : 0.0;
  uint64_t tmt = n_miss * miss_penalty;

  if (!quiet) {
    printf("块大小=%dB 块数=%d 路数=%d 替换=%s\n", block_bytes, n_blocks, n_ways, policy);
    printf("  访问次数 = %llu\n", (unsigned long long)n_access);
    printf("  命中     = %llu\n", (unsigned long long)n_hit);
    printf("  缺失     = %llu  (缺失率 %.4f)\n", (unsigned long long)n_miss, miss_rate);
    if (miss_penalty) printf("  TMT      = %llu 周期 (缺失代价取 %llu)\n",
                             (unsigned long long)tmt, (unsigned long long)miss_penalty);
  }
  printf("RESULT accesses=%llu hits=%llu misses=%llu miss_rate=%.6f tmt=%llu "
         "block=%d blocks=%d ways=%d policy=%s\n",
         (unsigned long long)n_access, (unsigned long long)n_hit,
         (unsigned long long)n_miss, miss_rate, (unsigned long long)tmt,
         block_bytes, n_blocks, n_ways, policy);
  free(lines);
  return 0;
}
