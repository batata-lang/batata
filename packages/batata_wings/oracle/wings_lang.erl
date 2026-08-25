%% Test-only headless replacement for the upstream translation service.
-module(wings_lang).
-export([str/2]).

str(_Key, Default) -> Default.
