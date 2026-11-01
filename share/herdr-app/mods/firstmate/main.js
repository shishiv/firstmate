// Firstmate homes and their workers: one group per firstmate.home label, one
// row per task terminal. Labels come from bin/backends/hc.sh; a task's project,
// open decision and PR come from <firstmate.home-path>/state/<id>.meta and
// <id>.status, re-read when watchFolder reports a change there.

import { View, div } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { terminals, agents, readTextFile, watchFolder, run, theme, exec, window } from "herdr";

const RANK = { blocked: 4, done: 3, working: 2, idle: 1 };
const LINE = /^([a-z-]+)((?:\s*\[[^\]]*\])*)\s*:\s?(.*)$/;
const PR = /https:\/\/\S+?\/(?:pull|merge_requests)\/\d+/;

function parseMeta(text) {
  const meta = {};
  for (const line of (text ?? "").split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) meta[line.slice(0, i)] = line.slice(i + 1);
  }
  return meta;
}

// Keyed needs-decision and blocked lines stay open until a resolved line with
// the same key; an unkeyed one is open only while it is the last line.
function parseStatus(text) {
  const open = new Map();
  let last = null;
  for (const raw of (text ?? "").split("\n")) {
    const m = LINE.exec(raw.trim());
    if (!m) continue;
    const key = /\[key=([^\]]+)\]/.exec(m[2])?.[1] ?? null;
    last = { state: m[1], key, text: m[3] };
    if (!key) continue;
    if (m[1] === "resolved") open.delete(key);
    else if (m[1] === "needs-decision" || m[1] === "blocked") open.set(key, last);
  }
  const waits = [...open.values()];
  if (last && !last.key && (last.state === "needs-decision" || last.state === "blocked")) waits.push(last);
  return { last, waits };
}

const taskId = (label) => label.replace(/^fm-/, "");
const baseName = (path) => (path ?? "").replace(/\/+$/, "").split("/").pop();

export default class Firstmate extends View {
  init() {
    this.tasks = new Map();
    this.watched = new Set();
  }

  async load(home, id) {
    const state = `${home}/state`;
    const [meta, status] = await Promise.all([
      readTextFile(`${state}/${id}.meta`).catch(() => null),
      readTextFile(`${state}/${id}.status`).catch(() => null),
    ]);
    this.tasks.set(`${home}\u0000${id}`, { meta: parseMeta(meta), ...parseStatus(status) });
  }

  // One watch per home: a change to a shown task's .meta or .status re-reads it.
  watch(home, cx) {
    if (this.watched.has(home)) return;
    this.watched.add(home);
    cx.spawn(async (cx) => {
      try {
        for (;;) {
          const changed = await watchFolder(`${home}/state`);
          const ids = new Set(changed.map((p) => /\/([^/]+)\.(?:meta|status)$/.exec(p)?.[1]).filter(Boolean));
          const shown = [...ids].filter((id) => this.tasks.has(`${home}\u0000${id}`));
          if (!shown.length) continue;
          await Promise.all(shown.map((id) => this.load(home, id)));
          cx.notify();
        }
      } catch {
        this.watched.delete(home);
      }
    });
  }

  fetch(home, id, cx) {
    const k = `${home}\u0000${id}`;
    if (this.tasks.has(k)) return;
    this.tasks.set(k, { meta: {}, last: null, waits: [] });
    cx.spawn(async (cx) => {
      await this.load(home, id);
      cx.notify();
    });
  }

  openUrl(url) {
    exec(window()?.platform === "macos" ? "open" : "xdg-open", [url]).catch(() => null);
  }

  badge(t, color, text) {
    return div().flex_none().px(6).h(18).rounded(5).bg(color + "26").text_size(10.5).font_semibold().text_color(color).flex().items_center().child(text);
  }

  dot(t, status) {
    if (status === "working") return div().size(7).mx(3).flex_none().rounded(4).bg(t.working).loop("opacity", { from: 0.35, to: 1, period: 1200 });
    if (status === "idle") return div().size(7).mx(3).flex_none().rounded(4).border(1.5).border_color(t.idle ?? t.dim);
    return div().size(7).mx(3).flex_none().rounded(4).bg(t[status] ?? t.dim);
  }

  row(t, w) {
    const pr = w.info.meta.pr || PR.exec(w.info.last?.state === "done" ? w.info.last.text : "")?.[0] || null;
    const wait = w.info.waits.length ? "Needs decision" : pr && w.info.last?.state === "done" ? "PR ready" : null;
    const project = baseName(w.info.meta.project);
    return h_flex()
      .id(`fm-${w.address}`)
      .px(8)
      .h(30)
      .flex_none()
      .rounded(8)
      .gap(8)
      .items_center()
      .cursor_pointer()
      .when(w.focused, (el) => el.bg(t.selected))
      .hover((s) => s.bg(t.hover))
      .tooltip(w.info.waits[0]?.text || w.info.last?.text || w.task)
      .on_click(() => run("pane.focus", { terminal: w.address }))
      .child(this.dot(t, w.status))
      .child(div().min_w(0).flex_1().truncate().text_color(w.status === "idle" ? t.muted : t.foreground).child(w.task))
      .when(Boolean(project), (el) => el.child(div().flex_none().max_w(90).truncate().text_size(11).text_color(t.dim).child(project)))
      .when(Boolean(wait), (el) => el.child(this.badge(t, wait === "PR ready" ? t.done : t.blocked, wait)))
      .when(Boolean(pr), (el) => el.child(div()
        .id(`fm-pr-${w.address}`)
        .flex_none()
        .text_size(11)
        .text_color(t.accent)
        .hover((s) => s.text_color(t.foreground))
        .tooltip(pr)
        .on_click((_e, cx) => {
          cx.stop_propagation();
          this.openUrl(pr);
        })
        .child(`#${pr.split("/").pop()}`)));
  }

  render(cx) {
    const t = theme();
    const status = new Map(agents().map((a) => [a.address, a]));
    const homes = new Map();
    for (const term of terminals()) {
      const labels = term.labels ?? {};
      const tag = labels["firstmate.home"];
      const label = labels["firstmate.task"];
      if (!tag || !label || term.state !== "live") continue;
      const path = labels["firstmate.home-path"] ?? null;
      const id = taskId(label);
      if (path) {
        this.watch(path, cx);
        this.fetch(path, id, cx);
      }
      const agent = status.get(term.address);
      const group = homes.get(tag) ?? { tag, name: baseName(path) || tag, workers: [] };
      group.workers.push({
        address: term.address,
        task: id,
        status: agent?.status ?? (RANK[term.status] ? term.status : "idle"),
        focused: agent?.focused ?? false,
        info: (path && this.tasks.get(`${path}\u0000${id}`)) || { meta: {}, last: null, waits: [] },
      });
      homes.set(tag, group);
    }
    const groups = [...homes.values()].sort((a, b) => a.name.localeCompare(b.name));
    for (const g of groups) g.workers.sort((a, b) => a.task.localeCompare(b.task));

    const header = (g) => {
      const waiting = g.workers.filter((w) => w.info.waits.length).length;
      return h_flex()
        .px(8)
        .pt(8)
        .h(30)
        .flex_none()
        .gap(6)
        .items_center()
        .text_size(11)
        .font_medium()
        .child(div().truncate().text_color(t.muted).child(g.name))
        .child(div().text_color(t.dim).child(String(g.workers.length)))
        .child(div().flex_1())
        .when(waiting > 0, (el) => el.child(this.badge(t, t.blocked, `${waiting} waiting`)));
    };

    return v_flex()
      .size_full()
      .min_h(0)
      .bg(t.chrome)
      .border_t(1)
      .border_color(t.border)
      .text_size(13)
      .child(h_flex().px(16).h(41).pt(14).pb(5).flex_none().items_center()
        .child(div().text_size(11.5).font_medium().text_color(t.dim).child("Firstmate")))
      .when(groups.length === 0, (el) => el.child(div().px(16).text_size(12).text_color(t.dim).child("No Firstmate workers. They show up here when a home spawns one on herdr-core.")))
      .child(v_flex().id("fm-list").flex_1().min_h(0).px(8).overflow_y_scrollbar()
        .children(groups.flatMap((g) => [header(g), ...g.workers.map((w) => this.row(t, w))])));
  }
}
