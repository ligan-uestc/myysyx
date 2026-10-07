CC ?= gcc
CFLAGS ?= -O2 -Wall

all: branchsim

branchsim: branchsim.c
	$(CC) $(CFLAGS) $< -o $@

clean:
	rm -f branchsim

.PHONY: all clean
