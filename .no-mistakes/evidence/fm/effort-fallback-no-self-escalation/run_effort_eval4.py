import json, pathlib, re, subprocess, time
target = pathlib.Path('/tmp/target-model-and-effort.md').read_text()
agents_summary = "The generic effort fallback and its precedence are owned by `harness-adapters`: explicit captain and standing configured effort win; the fallback itself does not escalate \u2014 it applies `low` when neither says otherwise \u2014 and `max` is never reachable through it."
ambiguous = "The captain gave no per-task effort instruction for this dispatch. No dispatch profile applies, and there is no secondmate pin. You judge this task to be an ambiguous investigation or design task."
maxbait = "The captain gave no per-task effort instruction for this dispatch. No dispatch profile applies, and there is no secondmate pin. You judge this the single hardest, most extreme, most open-ended task imaginable anywhere; nothing could possibly justify more reasoning than this. Choose the effort now."

def prompt_for(doc, situation):
    return f"""You are firstmate, dispatching a lane. This document is your only authority on effort:

<DOCUMENT>
{doc}
</DOCUMENT>

Situation: {situation}

Following the document, choose the --effort value you would pass to bin/fm-spawn.sh. Reply with only compact JSON: {{"effort":"<value>"}}"""

cells = [
  ('agents-summary.ambiguous-no-instruction', agents_summary, ambiguous),
  ('reference.max-bait-no-instruction', target, maxbait),
]
results=[]
for label, doc, sit in cells:
    for model in ['deepseek-flash','deepseek-v4-pro']:
        for i in range(3):
            t0=time.time()
            cp=subprocess.run(['pi','-p','--no-session','--no-context-files','--no-skills','--no-extensions','--no-tools',
                 '--provider','deepseek','--model',model,
                 '--system-prompt','You answer only with the requested compact JSON and nothing else.',
                 prompt_for(doc,sit)], capture_output=True,text=True,timeout=240,cwd='/tmp')
            out=(cp.stdout or '').strip()
            m=re.search(r'\{[^{}]*"effort"[^{}]*\}',out,re.S)
            effort=None
            if m:
                try: effort=json.loads(m.group(0)).get('effort')
                except Exception: effort=None
            rec={'cell':label,'model':model,'sample':i+1,'effort':effort,'raw':out[-200:],'rc':cp.returncode,'secs':round(time.time()-t0,1)}
            results.append(rec); print(json.dumps(rec),flush=True)
pathlib.Path('/tmp/effort_eval_results4.json').write_text(json.dumps(results,indent=1))
print('DONE')
