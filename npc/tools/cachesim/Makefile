CC ?= gcc
CFLAGS ?= -O2 -Wall

all: cachesim

cachesim: cachesim.c
	$(CC) $(CFLAGS) $< -o $@

# 设计空间探索: 需要先准备好 itrace (见 README)
dse: cachesim
	@test -n "$(TRACE)" || (echo "用法: make dse TRACE=/tmp/itrace.txt" >&2; exit 1)
	python3 dse.py $(TRACE)

clean:
	rm -f cachesim

.PHONY: all dse clean
