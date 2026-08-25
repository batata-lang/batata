%% Test-only headless replacement for the upstream wx progress bar.
-module(wings_pb).
-export([start/1, update/1, update/2, done/0, done/1]).

start(_Message) -> ok.
update(_Progress) -> ok.
update(_Progress, _Message) -> ok.
done() -> ok.
done(Result) -> Result.
