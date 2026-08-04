VCS ?= vcs
TEST ?= gq_smoke_test
BUILD_DIR ?= build
SIMV := $(BUILD_DIR)/simv

VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps
INCDIRS := +incdir+host_mem/src +incdir+src/gq +incdir+src/mailbox +incdir+tb
SOURCES := host_mem/src/host_mem_pkg.sv \
           src/gq/gq_pkg.sv \
           src/mailbox/mailbox_pkg.sv \
           tb/gq_test_pkg.sv \
           tb/tb_top.sv

.PHONY: build run

build: $(SIMV)

$(SIMV): $(SOURCES)
	mkdir -p $(BUILD_DIR)
	$(VCS) $(VCS_FLAGS) $(INCDIRS) $(SOURCES) -o $@

run: build
	$(SIMV) +UVM_TESTNAME=$(TEST)
