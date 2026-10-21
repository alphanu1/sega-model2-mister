# m2link: the Model 2 core's link-play helper for MiSTer's Linux (study R916).
#
#   make            m2link for this PC (tests)
#   make arm        build/arm/m2link, static, for the DE10-Nano (ARMv7 hard
#                   float), in a Debian container with g++-arm-linux-gnueabihf
#                   (image m2link-armcc:bookworm; see README.md)
#   make test       the local link tests (test/run_tests.sh)
#
# Sources: m2link.cpp and core_board.cpp (the recomp's CommBoard, split with the core);
# recomp/app/link_socket.cpp is the recomp's TcpLink, verbatim.

CXX      ?= g++
CXXFLAGS ?= -O2 -g -std=c++17 -Wall -Wextra
INC      := -I. -Irecomp
SRC      := m2link.cpp core_board.cpp recomp/app/link_socket.cpp
HDR      := core_board.h recomp/runtime/comm_board.h recomp/app/link_socket.h
B        := build

.PHONY: all arm test clean
all: $(B)/x86/m2link $(B)/x86/recomp_peer $(B)/x86/core_model $(B)/x86/test_comm_board

$(B)/x86/m2link: $(SRC) $(HDR)
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(INC) -o $@ $(SRC)

# The recomp's own code, verbatim, as the far end of every test.
$(B)/x86/recomp_peer: test/recomp_peer.cpp test/fake_game.h recomp/runtime/comm_board.cpp recomp/app/link_socket.cpp recomp/app/pacing.cpp recomp/app/pacing.h $(HDR)
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(INC) -o $@ test/recomp_peer.cpp recomp/runtime/comm_board.cpp recomp/app/link_socket.cpp recomp/app/pacing.cpp

$(B)/x86/core_model: test/core_model.cpp test/fake_game.h
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(INC) -o $@ test/core_model.cpp

$(B)/x86/test_comm_board: recomp/test_comm_board.cpp recomp/runtime/comm_board.cpp recomp/runtime/comm_board.h
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) $(INC) -o $@ recomp/test_comm_board.cpp recomp/runtime/comm_board.cpp

arm: $(SRC) $(HDR)
	@mkdir -p $(B)/arm
	docker run --rm -u $$(id -u):$$(id -g) -v "$(CURDIR)":/src -w /src m2link-armcc:bookworm \
	  arm-linux-gnueabihf-g++ -O2 -std=c++17 -Wall -Wextra -march=armv7-a -mfpu=neon -mfloat-abi=hard \
	  -static -s $(INC) -o $(B)/arm/m2link $(SRC)
	file $(B)/arm/m2link

test: all
	./test/run_tests.sh

clean:
	rm -rf $(B)
