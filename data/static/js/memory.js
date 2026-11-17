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
  if (msg) msg.textContent = "Asking the model to draft a graph…";
  if (btn) btn.disabled = true;
  let r;
  try {
    r = await postJSON("/api/memory", {action:"skill_graph_propose", skill: slug});
  } catch(e) { r = {error: String((e && e.message) || e)}; }
  if (btn) btn.disabled = false;
  if (!msg || !box) return;
  if (r.error){ msg.textContent = "Error: "+r.error; return; }
  skillGraphDrafts[i] = r.graph;
  msg.textContent = "Draft ready — review it, then approve to compile and install.";
  box.innerHTML = uiCard(`<pre style="font-family:var(--face-mono);font-size:var(--text-xs);color:var(--text-muted);white-space:pre-wrap;max-height:320px;overflow:auto;margin:0">${esc(r.graph)}</pre>
    <div style="margin-top:var(--space-2)">${uiButton("Approve & install", {level: "primary", onclick: `approveSkillGraph(${i})`, attrs: `id="skgraph-ok-${i}"`})}</div>`);
}
async function approveSkillGraph(i){
  const msg = document.getElementById("skgraph-msg-"+i);
  const btn = document.getElementById("skgraph-ok-"+i);
  const graph = skillGraphDrafts[i];
  if (!graph){ if (msg) msg.textContent = "Nothing to approve — propose a graph first."; return; }
  if (msg) msg.textContent = "Compiling and installing…";
  if (btn) btn.disabled = true;
  let r;
  try {
    r = await postJSON("/api/memory", {action:"skill_graph_approve", graph});
  } catch(e) { r = {error: String((e && e.message) || e)}; }
  if (!msg) return;
  if (r.error){ msg.textContent = "Error: "+r.error; if (btn) btn.disabled = false; return; }
  delete skillGraphDrafts[i];
  msg.textContent = "Installed at "+r.plugin_path+" (compiled: "+r.compiled+", replaced: "+r.replaced+").";
}
