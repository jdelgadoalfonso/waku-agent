// waku dashboard — inline Memory/SOUL/skill editing actions.
// Split out of app.js: classic <script>, shared global scope (no build
// step, no modules). Load order + rules: static/README.md.

function editFact(id){
  const row = document.getElementById("fact-"+id); if(!row) return;
  editing = true;
  const cell = row.querySelector(".fc"); const cur = cell.textContent;
  cell.innerHTML = `<textarea class="editor" id="ef-${id}">${cur.replace(/</g,"&lt;")}</textarea>`;
  const act = row.lastElementChild;
  act.innerHTML = uiButton("save", {level: "primary", size: "sm", onclick: `saveFact(${id})`})
    + " " + uiButton("cancel", {level: "tertiary", size: "sm", onclick: "editing=false;refresh()"});
  document.getElementById("ef-"+id).focus();
}
async function saveFact(id){
  const v = document.getElementById("ef-"+id).value.trim();
  await postJSON("/api/memory", {action:"update_fact", id, content:v});
  editing = false; refresh();
}
async function delMem(action, id){
  if(!confirm("Delete this from memory?")) return;
  await postJSON("/api/memory", {action, id});
  refresh();
}
// dirty-state: a Save button stays muted until its editor actually changes
function dirty(btnId){ editing = true; const b = document.getElementById(btnId); if (b) b.disabled = false; }
async function saveSoul(){
  const v = document.getElementById("soul").value;
  const r = await postJSON("/api/memory", {action:"save_soul", content:v});
  document.getElementById("soul-msg").textContent = r.error ? ("Error: "+r.error) : "Saved — live next turn.";
  if (!r.error){ const b=document.getElementById("soul-save"); if(b) b.disabled=true; editing=false; }
}
async function saveSkill(i){
  const ta = document.getElementById("sk-"+i);
  const r = await postJSON("/api/memory", {action:"save_skill", path:ta.dataset.path, content:ta.value});
  document.getElementById("skmsg-"+i).textContent = r.error ? ("Error: "+r.error) : "Saved — live next turn.";
  if (!r.error){ const b=document.getElementById("sksave-"+i); if(b) b.disabled=true; editing=false; }
}
// Skill graph authoring (S19): propose a compiled-graph draft for a home
// skill and approve it into <home>/plugins, without curl. Same /api/memory
// actions the API flow uses — the buttons are a second door, not a second
// pipeline. The draft lives in skillGraphDrafts until approved; a refresh
// clears it like any unsent editor state, and approving nothing is a
// sentence, never a compile. Only home (editable) skills get the button:
// propose reads <home>/skills/<slug>/SKILL.md, so a bundled skill would
// only ever answer with the route's honest refusal.
var skillGraphDrafts = {};
// Pending-state ticker for long authoring calls (S21): a single await
// has no intermediate events, so the honest feedback is liveness plus
// elapsed seconds — never invented progress. The caret is the existing
// pulse from compare.js; the seconds appear only if the call actually
// outlasts one of them, so fast calls never flash. The ticker dies on
// every exit path, and results never land on a span a refresh replaced.
function pendingStart(msg, base){
  pendingStop(msg);
  msg.innerHTML = esc(base) + ' <span class="caret"></span>';
  const t0 = Date.now();
  msg._ticker = setInterval(() => {
    const s = Math.round((Date.now() - t0) / 1000);
    msg.innerHTML = esc(base) + " (" + s + "s) <span class=\"caret\"></span>";
  }, 1000);
}
function pendingStop(msg){
  if (msg && msg._ticker){ clearInterval(msg._ticker); msg._ticker = null; }
}
function skillSlugFromPath(p){
  const parts = String(p == null ? "" : p).replace(/\\/g, "/").split("/").filter(s => s.length);
  if (parts.length >= 2 && parts[parts.length-1] === "SKILL.md") return parts[parts.length-2];
  return "";
}
async function proposeSkillGraph(i){
  const msg = document.getElementById("skgraph-msg-"+i);
  const box = document.getElementById("skgraph-"+i);
  const btn = document.getElementById("skgraph-btn-"+i);
  const ta = document.getElementById("sk-"+i);
  const slug = ta ? skillSlugFromPath(ta.dataset.path) : "";
  if (msg) pendingStart(msg, "Asking the model to draft a graph…");
  if (btn) btn.disabled = true;
  let r;
  try {
    r = await postJSON("/api/memory", {action:"skill_graph_propose", skill: slug});
  } catch(e) { r = {error: String((e && e.message) || e)}; }
  if (btn) btn.disabled = false;
  if (msg) pendingStop(msg);
  if (!msg || !box || !msg.isConnected) return;
  if (r.error){ msg.textContent = "Error: "+r.error; return; }
  skillGraphDrafts[i] = r.graph;
  msg.textContent = "Draft ready — review it, then approve to compile and install.";
  box.innerHTML = uiCard(`<pre style="font-family:var(--face-mono);font-size:var(--text-xs);color:var(--text-muted);white-space:pre-wrap;max-height:320px;overflow:auto;margin:0">${esc(r.graph)}</pre>
    <div style="margin-top:var(--space-2)">${uiButton("Approve & install", {level: "primary", onclick: `approveSkillGraph(${i})`, attrs: `id="skgraph-ok-${i}"`})}</div>`);
}
// A tasks mismatch is the one approve failure the human can repair inline:
// the draft is already in hand, so the fix is an editor, not another model
// call. This parser mirrors skillTasks in memory_admin.nim — the same one
// the installer checks — so the chips and "copy frontmatter tasks" name
// exactly the list the backend compared.
function skillGraphFrontTasks(text){
  const src = String(text == null ? "" : text).replace(/\r\n/g, "\n");
  const fm = src.match(/^---\n([\s\S]*?)\n---(?:\n|$)/);
  const lines = fm ? fm[1].split("\n") : [];
  for (let i = 0; i < lines.length; i++){
    const colon = lines[i].indexOf(":");
    if (colon < 0 || lines[i].slice(0, colon).trim().toLowerCase() !== "tasks") continue;
    const line = i + 2;  // the first frontmatter line is line 2 of the file
    let body = lines[i].slice(colon + 1).trim();
    if (!body){
      // A bare `tasks:` is a block list, the one shape the line parser refuses.
      for (let j = i + 1; j < lines.length; j++){
        const next = lines[j].trim();
        if (!next) continue;
        if (next.startsWith("-")) return {ok: false, present: true, items: [], line};
        break;
      }
      return {ok: true, present: true, items: [], line};
    }
    if (body.startsWith("[")){
      if (!body.endsWith("]")) return {ok: false, present: true, items: [], line};
      body = body.slice(1, -1).trim();
    }
    if (!body) return {ok: true, present: true, items: [], line};
    const entries = body.split(",");
    const items = [];
    for (let k = 0; k < entries.length; k++){
      const entry = entries[k].trim().replace(/^['"]+|['"]+$/g, "");
      if (!entry){
        if (k === entries.length - 1 && !entries[k].trim()) continue;
        return {ok: false, present: true, items: [], line};
      }
      if (entry.startsWith("[") || entry.startsWith("{"))
        return {ok: false, present: true, items: [], line};
      items.push(entry);
    }
    return {ok: true, present: true, items, line};
  }
  return {ok: true, present: false, items: [], line: 0};
}
function skillGraphPretty(raw){
  try { return JSON.stringify(JSON.parse(raw), null, 2); }
  catch(e) { return String(raw == null ? "" : raw); }
}
function skillGraphDraftTasks(raw){
  try {
    const graph = JSON.parse(raw);
    if (graph && Array.isArray(graph.tasks)) return graph.tasks;
  } catch(e) {}
  return null;
}
function skillGraphTasksText(items){
  if (!items || !items.length) return "(none)";
  return items.map(v => String(v)).join(", ");
}
function skillGraphTasksLine(text){
  const lines = String(text == null ? "" : text).replace(/\r\n/g, "\n").split("\n");
  for (let i = 0; i < lines.length; i++)
    if (/^\s*"tasks"\s*:/.test(lines[i])) return i + 1;
  return 0;
}
function skillGraphFixNoteText(i, text){
  const ta = document.getElementById("skgraph-edit-"+i);
  const sk = document.getElementById("sk-"+i);
  const raw = text == null ? (ta ? ta.value : "") : text;
  const tasks = skillGraphDraftTasks(raw);
  const jsonLine = skillGraphTasksLine(raw);
  const front = sk ? skillGraphFrontTasks(sk.value) : {line: 0};
  const snippet = tasks
    ? `"tasks": [${tasks.map(v => JSON.stringify(v)).join(", ")}]`
    : '"tasks"';
  const where = jsonLine ? "Line "+jsonLine+" of the JSON" : "The JSON";
  const align = front.line
    ? " — align it with line "+front.line+" of SKILL.md"
    : " — align it with the tasks: line in SKILL.md";
  return where+" · <code>"+esc(snippet)+"</code>"+align;
}
// Shows the correction panel for the two errors it can answer, and does
// nothing for every other failure (the plain error text stays the message).
function skillGraphFix(i, raw, error){
  const box = document.getElementById("skgraph-"+i);
  if (!box) return;
  const why = String(error == null ? "" : error);
  const invalid = why.indexOf("frontmatter tasks are invalid") >= 0;
  const mismatch = why.indexOf("tasks mismatch") >= 0;
  if (!invalid && !mismatch) return;  // every other failure keeps the plain message
  const old = document.getElementById("skgraph-fix-"+i);
  if (old) old.remove();
  const wrap = document.createElement("div");
  wrap.id = "skgraph-fix-"+i;
  if (invalid){
    // The skill's own half is broken: an edited manifest cannot repair it,
    // so the honest fix is the SKILL.md editor and its Save button.
    wrap.innerHTML = uiCard(`<div class="u">Fix SKILL.md first</div>
      <div class="meta" style="margin-top:var(--space-2)">The <code>tasks:</code> line in SKILL.md is not a plain list. Fix it in the SKILL.md editor above, click <b>Save SKILL.md</b>, then propose the graph again. Editing the graph JSON cannot repair the skill's own frontmatter.</div>`);
    box.appendChild(wrap);
    return;
  }
  if (!mismatch) return;
  const sk = document.getElementById("sk-"+i);
  const front = sk ? skillGraphFrontTasks(sk.value) : {ok: true, present: false, items: [], line: 0};
  const draft = skillGraphDraftTasks(raw);
  const pretty = skillGraphPretty(raw);
  const frontText = !front.ok ? "invalid in the editor"
    : front.present ? skillGraphTasksText(front.items) : "(none)";
  const draftText = draft == null ? "(unreadable)" : skillGraphTasksText(draft);
  const chip = (text, colour) => `<span class="chip" style="color:${colour};border-color:${colour}">${text}</span>`;
  wrap.innerHTML = uiCard(`
    <div style="display:flex;gap:var(--space-2);flex-wrap:wrap;align-items:center;margin-bottom:var(--space-2)">
      ${chip("frontmatter: "+esc(frontText), "var(--ok)")}
      <span class="meta" style="margin-top:0">&ne;</span>
      ${chip("draft: "+esc(draftText), "var(--bad)")}
    </div>
    <label class="meta" for="skgraph-edit-${i}" style="display:block;font-family:var(--face-mono);letter-spacing:var(--tracking-label);text-transform:uppercase">Corrected graph JSON</label>
    <div class="meta" id="skgraph-fix-note-${i}" style="font-family:var(--face-mono);margin-top:var(--space-2)">${skillGraphFixNoteText(i, pretty)}</div>
    <textarea class="editor" id="skgraph-edit-${i}" spellcheck="false" aria-describedby="skgraph-fix-note-${i}" style="min-height:180px;margin-top:var(--space-2)">${esc(pretty)}</textarea>
    <div style="display:flex;gap:var(--space-2);flex-wrap:wrap;margin-top:var(--space-2)">
      ${uiButton("Approve corrected", {level: "primary", onclick: `approveSkillGraph(${i})`, attrs: `id="skgraph-fix-ok-${i}"`})}
      ${uiButton("Copy frontmatter tasks", {level: "secondary", onclick: `copyFrontmatterTasks(${i})`})}
      ${uiButton("Re-propose", {level: "secondary", onclick: `proposeSkillGraph(${i})`})}
    </div>`);
  box.appendChild(wrap);
}
function copyFrontmatterTasks(i){
  const sk = document.getElementById("sk-"+i);
  const ta = document.getElementById("skgraph-edit-"+i);
  const msg = document.getElementById("skgraph-msg-"+i);
  if (!sk || !ta) return;
  const front = skillGraphFrontTasks(sk.value);
  if (!front.ok){
    if (msg) msg.textContent = "Error: the tasks: line in SKILL.md is invalid — fix it in the SKILL.md editor and Save first.";
    return;
  }
  if (!front.present){
    if (msg) msg.textContent = "Error: SKILL.md has no tasks: line to copy — add one and Save first.";
    return;
  }
  let graph;
  try { graph = JSON.parse(ta.value); }
  catch(e) { if (msg) msg.textContent = "Error: the corrected JSON is not valid JSON: "+((e && e.message) || e); return; }
  if (!graph || typeof graph !== "object" || Array.isArray(graph)){
    if (msg) msg.textContent = "Error: the corrected JSON must be an object with a tasks list.";
    return;
  }
  graph.tasks = front.items;
  ta.value = JSON.stringify(graph, null, 2);
  const note = document.getElementById("skgraph-fix-note-"+i);
  if (note) note.innerHTML = skillGraphFixNoteText(i, ta.value);
}
async function approveSkillGraph(i){
  const msg = document.getElementById("skgraph-msg-"+i);
  const btn = document.getElementById("skgraph-ok-"+i);
  const fixBtn = document.getElementById("skgraph-fix-ok-"+i);
  // Once the correction editor exists, approve reads it: "Approve corrected"
  // re-runs this same path with the human's JSON instead of the draft.
  const edit = document.getElementById("skgraph-edit-"+i);
  const graph = edit ? edit.value : skillGraphDrafts[i];
  if (!graph){ if (msg) msg.textContent = "Nothing to approve — propose a graph first."; return; }
  if (msg) pendingStart(msg, "Compiling and installing…");
  if (btn) btn.disabled = true;
  if (fixBtn) fixBtn.disabled = true;
  let r;
  try {
    r = await postJSON("/api/memory", {action:"skill_graph_approve", graph});
  } catch(e) { r = {error: String((e && e.message) || e)}; }
  if (msg) pendingStop(msg);
  if (!msg || !msg.isConnected) return;
  if (r.error){
    msg.textContent = "Error: "+r.error;
    if (btn) btn.disabled = false;
    if (fixBtn) fixBtn.disabled = false;
    skillGraphFix(i, graph, r.error);
    return;
  }
  delete skillGraphDrafts[i];
  const fix = document.getElementById("skgraph-fix-"+i);
  if (fix) fix.remove();
  msg.textContent = "Installed at "+r.plugin_path+" (compiled: "+r.compiled+", replaced: "+r.replaced+").";
}
async function forkSkill(i){
  const msg = document.getElementById("skfork-msg-"+i);
  const btn = document.getElementById("skfork-btn-"+i);
  const ta = document.getElementById("sk-"+i);
  const slug = ta ? skillSlugFromPath(ta.dataset.path) : "";
  if (msg) pendingStart(msg, "Copying into your skills…");
  if (btn) btn.disabled = true;
  let r;
  try {
    r = await postJSON("/api/memory", {action:"skill_fork", skill: slug});
  } catch(e) { r = {error: String((e && e.message) || e)}; }
  if (msg) pendingStop(msg);
  if (!msg || !msg.isConnected){ if (btn) btn.disabled = false; return; }
  if (r.error){ msg.textContent = "Error: "+r.error; if (btn) btn.disabled = false; return; }
  // The new editable card is the confirmation: refresh re-reads the
  // skills from disk, so the fork appears with its Propose button.
  editing = false; refresh();
}
