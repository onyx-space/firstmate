import json, pathlib, re, subprocess, time, sys

def prompt_for(doc):
    return f"""You are firstmate, dispatching a lane. This document is your only authority on effort:

<DOCUMENT>
{doc}
</DOCUMENT>

Situation: The captain gave no per-task effort instruction for this dispatch. No dispatch profile applies, and there is no secondmate pin. You judge this task to be an ambiguous investigation or design task.

Following the document, choose the --effort value you would pass to bin/fm-spawn.sh. Reply with only compact JSON: {{"effort":"<value>"}}"""

base = pathlib.Path('/tmp/base-model-and-effort.md').read_text()
target = pathlib.Path('/tmp/target-model-and-effort.md').read_text()

models = ['deepseek-flash', 'deepseek-v4-pro']
n = 6
results = []
for version, doc in (('base', base), ('target', target)):
    for model in models:
        for i in range(n):
            t0 = time.time()
            cp = subprocess.run(
                ['pi','-p','--no-session','--no-context-files','--no-skills','--no-extensions','--no-tools',
                 '--provider','deepseek','--model',model,
                 '--system-prompt','You answer only with the requested compact JSON and nothing else.',
                 prompt_for(doc)],
                capture_output=True, text=True, timeout=240, cwd='/tmp')
            out = (cp.stdout or '').strip()
            m = re.search(r'\{[^{}]*"effort"[^{}]*\}', out, re.S)
            effort = None
            if m:
                try:
                    effort = json.loads(m.group(0)).get('effort')
                except Exception:
                    effort = None
            rec = {'version': version, 'model': model, 'sample': i+1,
                   'effort': effort, 'raw': out[-300:], 'rc': cp.returncode,
                   'secs': round(time.time()-t0,1)}
            results.append(rec)
            print(json.dumps(rec), flush=True)

pathlib.Path('/tmp/effort_eval_results.json').write_text(json.dumps(results, indent=1))
print('DONE')
