FROM ghcr.io/berriai/litellm:main-stable

WORKDIR /app

# Fix: Opus 4.7 rejects interleaved-thinking and context-management beta flags.
# LiteLLM's bedrock provider maps these as supported, causing 400 errors.
# Set them to null so they're dropped before the Bedrock API call.
RUN python3 -c "\
import json, os; \
p = next(f for d,_,fs in os.walk('/') for f in fs if f == 'anthropic_beta_headers_config.json' and 'litellm' in d); \
c = json.load(open(p)); \
[c[pv].update({'interleaved-thinking-2025-05-14': None, 'context-management-2025-06-27': None}) \
 for pv in ['bedrock', 'bedrock_converse'] if pv in c]; \
json.dump(c, open(p,'w'), indent=4); \
print('Patched:', p)"

# Use local (patched) config — don't fetch remote which would override the fix
ENV LITELLM_LOCAL_ANTHROPIC_BETA_HEADERS=True
