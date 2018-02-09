NAME=backend

all: compile

compile:
	./rebar compile

release:
	cd rel && ../rebar generate && cd -

node:
	(cd rel && ../rebar create-node nodeid=${NAME} && cd -)

clean:
	./rebar clean
	rm -rf rel/${NAME}

start:
	rel/${NAME}/bin/${NAME} start

stop:
	rel/${NAME}/bin/${NAME} stop

console:
	rel/${NAME}/bin/${NAME} console

alldev: clean all runconsole
