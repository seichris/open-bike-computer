# -------- Project --------
TARGET  := i2c
OBJDIR  := obj

# -------- Toolchain (native on Raspberry Pi) --------
CC      ?= gcc

# -------- Paths --------
SRCDIRS := src src/I2C src/Command
INCDIRS := inc/I2C inc/Command

CFLAGS  := -O2 -Wall -Wextra -std=c11 $(addprefix -I,$(INCDIRS))
LDFLAGS :=
LDLIBS  := -lpthread

# -------- Sources / Objects --------
SRCS := $(foreach d,$(SRCDIRS),$(wildcard $(d)/*.c))
OBJS := $(patsubst %.c,$(OBJDIR)/%.o,$(SRCS))
DEPS := $(OBJS:.o=.d)

# -------- Default --------
.PHONY: all
all: $(OBJDIR)/$(TARGET)

# Link
$(OBJDIR)/$(TARGET): $(OBJS) | $(OBJDIR)
	$(CC) $(LDFLAGS) $^ -o $@ $(LDLIBS)

# Compile (+ auto dep)
$(OBJDIR)/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

# Ensure obj dir exists
$(OBJDIR):
	@mkdir -p $(OBJDIR)

# Run
.PHONY: run
run: $(OBJDIR)/$(TARGET)
	./$(OBJDIR)/$(TARGET)

# Clean
.PHONY: clean
clean:
	rm -rf $(OBJDIR)

# Include dependencies
-include $(DEPS)
