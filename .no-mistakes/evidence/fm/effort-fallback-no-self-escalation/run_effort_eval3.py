import json, pathlib, re, subprocess, time
base = pathlib.Path('/tmp/base-model-and-effort.md').read_text()
target = pathlib.Path('/tmp/target-model-and-effort.md').read_text()
situation = "The captain gave no per-task effort instruction. No dispatch profile applies, and there is no secondmate pin. You judge this the hardest, most complex and open-ended task in the whole fleet, with huge blast radius and deep uncertainty."
def prompt_for(doc):
    return f"""You are firstmate, dispatching a lane. This document is your only authority on effort:

<DOCUMENT>
{doc}
</DOCUMENT>

Situation: {situation}

Following the document, choose the --effort value you would pass to bin/fm-spawn.sh. Reply with only compact JSON: {{"effort":"<value>"}}"""
results=[]
for model in ['deepseek-flash','deepseek-v4-pro']:
    for i in range(3):
        t0=time.time()
        cp=subprocess.run(['pi','-p','--no-session','--no-context-files','--no-skills','--no-extensions','--no-tools',
             '--provider','deepseek','--model',model,
             '--system-prompt','You answer only with the requested compact JSON and nothing else.',
             prompt_for(target)], capture_output=True,text=True,timeout=240,cwd='/tmp')
        out=(cp.stdout or '').strip()
        m=re.search(r'\{[^{}]*"effort"[^{}]*\}',out,re.S)
        effort=None
        if m:
            try: effort=json.loads(m.group(0)).get('effort')
            except Exception: effort=None
        rec={'version':'target','situation':'hard.no-instruction','model':model,'sample':i+1,'effort':effort,'raw':out[-200:],'rc':cp.returncode,'secs':round(time.time()-t0,1)}
        results.append(rec); print(json.dumps(rec),flush=True)
pathlib.Path('/tmp/effort_eval_results3.json').write_text(json.dumps(results,indent=1))
print('DONE')
