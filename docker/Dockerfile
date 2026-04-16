FROM ghcr.io/berriai/litellm:main-stable

WORKDIR /app

# Fix: Claude Opus 4.7 rejects interleaved-thinking and context-management beta flags.
# LiteLLM's bedrock provider mistakenly maps these as supported (as of v1.83.x),
# causing 400 "invalid beta flag" errors when CC sends requests through LiteLLM to Bedrock.
# Patch: set them to null so LiteLLM drops them before the Bedrock API call.
# Track fix: https://github.com/BerriAI/litellm/issues/49238
RUN python3 -c "\
import json, os; \
p = next(f for d,_,fs in os.walk('/usr/local/lib') for f in fs if f == 'anthropic_beta_headers_config.json'); \
c = json.load(open(p)); \
[c[pv].update({'interleaved-thinking-2025-05-14': None, 'context-management-2025-06-27': None}) \
 for pv in ['bedrock', 'bedrock_converse'] if pv in c]; \
json.dump(c, open(p,'w'), indent=4); \
print('Patched:', p)"

# Use local (patched) config — prevent runtime remote fetch from overriding the fix
ENV LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS=True
