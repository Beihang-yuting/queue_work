VCS ?= vcs
TEST ?= gq_smoke_test
BUILD_DIR ?= build
SIMV := $(BUILD_DIR)/simv

LIBS ?= mailbox
comma := ,
LIB_LIST := $(subst $(comma), ,$(LIBS))
LIB_SOURCE_mailbox := src/mailbox/mailbox_pkg.sv
LIB_SOURCE_msgq := src/msgq/msgq_pkg.sv
LIB_SOURCE_cmdq := src/cmdq/cmdq_pkg.sv
LIB_SOURCES := $(foreach lib,$(LIB_LIST),$(LIB_SOURCE_$(lib)))
LIB_INCDIRS := $(foreach lib,$(LIB_LIST),+incdir+src/$(lib))
TEST_SUITE ?= gq
TEST_PACKAGE_gq := tb/gq_test_pkg.sv
TEST_PACKAGE_msgq := tb/msgq_test_pkg.sv
TEST_PACKAGE_cmdq := tb/cmdq_test_pkg.sv
TEST_DEFINE_gq := +define+QUEUE_TEST_GQ
TEST_DEFINE_msgq := +define+QUEUE_TEST_MSGQ
TEST_DEFINE_cmdq := +define+QUEUE_TEST_CMDQ
TEST_PACKAGE_SOURCE := $(TEST_PACKAGE_$(TEST_SUITE))
UNKNOWN_LIBS := $(foreach lib,$(LIB_LIST),\
                  $(if $(LIB_SOURCE_$(lib)),,$(lib)))

ifneq ($(strip $(UNKNOWN_LIBS)),)
$(error unknown LIBS entries: $(UNKNOWN_LIBS))
endif
ifeq ($(strip $(TEST_PACKAGE_SOURCE)),)
$(error unknown TEST_SUITE: $(TEST_SUITE))
endif

VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps
INCDIRS := +incdir+host_mem/src +incdir+src/gq $(LIB_INCDIRS) +incdir+tb
SOURCES := host_mem/src/host_mem_pkg.sv src/gq/gq_pkg.sv \
           $(LIB_SOURCES) $(TEST_PACKAGE_SOURCE) tb/tb_top.sv
VCS_FLAGS += $(TEST_DEFINE_$(TEST_SUITE))

.PHONY: build vcs run check-layout

build: vcs

vcs:
	mkdir -p $(BUILD_DIR)
	env -u LIBS -u MAKEFLAGS -u MFLAGS \
		$(VCS) $(VCS_FLAGS) $(INCDIRS) $(SOURCES) -o $(SIMV)

check-layout:
	./scripts/check_sv_layout.sh

run: vcs
	$(SIMV) +UVM_TESTNAME=$(TEST)
