"""Tests for taskchy.py, in a throwaway home (its own notes folder).
Run: python3 -m unittest discover -s tests"""
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout

HOME = tempfile.mkdtemp(prefix="taskchy-test-")
os.environ["HOME"] = HOME
os.umask(0o022)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import taskchy as tc  # noqa: E402

ROOT = os.path.join(HOME, "Documents/Taskchy")


def run(*argv):
    with redirect_stdout(io.StringIO()):
        return tc.run([str(a) for a in argv])


def read(path):
    with open(path) as f:
        return f.read()


def todo_file(tid):
    return os.path.join(ROOT, "Todos", tid + ".md")


def subs(tid):
    return [(s["state"], s["text"]) for s in tc.summary(ROOT, tid)["subs"]]


OBSIDIAN = """---
group: Test
done: false
created: 2026-10-03 11:00
priority: high
---
# Hand edited

Some intro notes, with a [link](https://example.com).

- [ ] first sub-todo
- [-] cancelled (Obsidian Tasks style)
- [>] deferred
- plain bullet, no checkbox
* [X] done one
  ![pic](../Attachments/x.png)
  a note written after the picture

## Notes
More notes at the end.
"""


class InPlace(unittest.TestCase):
    def setUp(self):
        run("folder", "")
        tc.ensure(ROOT)
        with open(todo_file("hand"), "w") as f:
            f.write(OBSIDIAN)

    def text(self):
        return read(todo_file("hand"))

    def test_unchanged_save_is_identical(self):
        t = tc.load(ROOT, "hand")
        self.assertEqual(tc.render(t), OBSIDIAN)

    def test_state_change_touches_one_line(self):
        run("sub-set", "hand", 0, "doing")
        self.assertEqual(self.text(), OBSIDIAN.replace("- [ ] first sub-todo", "- [/] first sub-todo"))

    def test_nothing_unknown_is_lost(self):
        run("sub-add", "hand", "a new one")
        run("sub-move", "hand", 2, 0)
        run("sub-edit", "hand", 2, "done one, edited")
        run("group", "hand", "Other")
        run("rename", "hand", "Renamed")
        text = self.text()
        for keep in ("Some intro notes", "- [-] cancelled", "- [>] deferred", "- plain bullet, no checkbox",
                     "  a note written after the picture", "## Notes", "More notes at the end.", "priority: high"):
            self.assertIn(keep, text)
        self.assertIn("group: Other", text)
        self.assertIn("# Renamed", text)
        self.assertEqual(subs("hand"), [("todo", "a new one"), ("todo", "first sub-todo"),
                                        ("done", "done one, edited")])
        # the note under the picture stays with its sub-todo
        self.assertLess(text.index("done one, edited"), text.index("a note written after the picture"))

    def test_multiline_sub_todo(self):
        run("sub-edit", "hand", 0, "line one\n\nline two")
        self.assertEqual(subs("hand")[0], ("todo", "line one\n\nline two"))
        self.assertIn("- [ ] line one\n\n  line two\n- [-] cancelled", self.text())

    def test_first_sub_todo_after_the_title(self):
        tid = run("add", "Empty one")["id"]
        with open(todo_file(tid), "a") as f:
            f.write("Notes kept below.\n")
        run("sub-add", tid, "first")
        text = read(todo_file(tid))
        self.assertLess(text.index("- [ ] first"), text.index("Notes kept below."))
        self.assertEqual(subs(tid), [("todo", "first")])


class Safety(unittest.TestCase):
    def setUp(self):
        run("folder", "")
        tc.ensure(ROOT)
        self.tid = run("add", "Safe")["id"]
        for s in ("one", "two", "three"):
            run("sub-add", self.tid, s)

    def test_ids_stay_in_the_folder(self):
        with open(os.path.join(ROOT, "outside.md"), "w") as f:
            f.write("x\n")
        for bad in ("../outside", "../../etc/passwd", ".taskchy/x", "a/b", "..", ""):
            with self.assertRaises(tc.Fail, msg=bad):
                run("delete", bad)
        self.assertTrue(os.path.exists(os.path.join(ROOT, "outside.md")))
        tc.check_id("My todo")   # a notes app's own file name is fine

    def test_stale_position_changes_nothing(self):
        with self.assertRaises(tc.Fail):
            run("sub-delete", self.tid, 0, "--expect", "two")
        with self.assertRaises(tc.Fail):
            run("sub-move", self.tid, 0, 2, "--expect", "three")
        self.assertEqual([t for _, t in subs(self.tid)], ["one", "two", "three"])
        run("sub-delete", self.tid, 1, "--expect", "two")
        self.assertEqual([t for _, t in subs(self.tid)], ["one", "three"])
        trash = read(os.path.join(ROOT, ".taskchy/trash/deleted-sub-todos.md"))
        self.assertIn("- [ ] two", trash)

    def test_log_heading_in_a_message(self):
        msg = "Pasted:\n## 2026-01-01 09:00 · build bot\nall green"
        run("log", self.tid, msg, "--by", "claude")
        e = tc.log_entries(ROOT, self.tid)
        self.assertEqual([(x["by"], x["text"]) for x in e], [("claude", msg)])
        run("log-edit", self.tid, 0, msg + "\nmore", "--expect", msg)
        self.assertEqual(tc.log_entries(ROOT, self.tid)[0]["text"], msg + "\nmore")

    def test_one_bad_file_doesnt_empty_the_list(self):
        with open(todo_file("junk"), "wb") as f:
            f.write(b"\xff\xfe not text")
        with open(todo_file(self.tid)) as f:
            text = f.read()
        with open(todo_file(self.tid), "w") as f:
            f.write(text.replace("done: false", "done: false\norder: first"))
        out = run("list")
        self.assertIn(self.tid, [t["id"] for t in out["todos"]])
        self.assertEqual([b["id"] for b in out["broken"]], ["junk"])
        os.remove(todo_file("junk"))

    def test_permissions_kept(self):
        self.assertEqual(os.stat(todo_file(self.tid)).st_mode & 0o777, 0o644)
        os.chmod(todo_file(self.tid), 0o640)
        run("sub-add", self.tid, "four")
        self.assertEqual(os.stat(todo_file(self.tid)).st_mode & 0o777, 0o640)


class Groups(unittest.TestCase):
    def setUp(self):
        run("folder", "")
        tc.ensure(ROOT)

    def test_group_life(self):
        a = run("add", "In A", "--group", "A")["id"]
        b = run("add", "In B", "--group", "B")["id"]
        g = tc.groups(ROOT)
        self.assertNotEqual(g["A"]["color"], g["B"]["color"])
        run("group-rename", "A", "A2")
        self.assertEqual(tc.summary(ROOT, a)["group"], "A2")
        run("super-set", "A2", "Big")
        run("super-set", "B", "Big")
        self.assertEqual(sorted(run("super-archive", "Big")["archived"]), sorted([a, b]))
        self.assertEqual(sorted(run("group-restore", "B")["restored"]), [b])
        run("group-delete", "A2")
        self.assertEqual(tc.summary(ROOT, a, archived=True)["group"], "")
        self.assertNotIn("A2", tc.groups(ROOT))


if __name__ == "__main__":
    unittest.main()


class AgentWorkflow(unittest.TestCase):
    """What the Claude skill drives: plan, start, log, finish, find."""

    def setUp(self):
        run("folder", "")
        tc.ensure(ROOT)

    def test_plan_start_log_finish(self):
        r = run("plan", "Agent Project", "--group", "Work", "--sub", "one", "--sub", "two", "--by", "Claude")
        tid = r["id"]
        self.assertEqual(subs(tid), [("todo", "one"), ("todo", "two")])
        run("start", tid, 0, "picking it up", "--by", "Claude")
        self.assertEqual(subs(tid)[0][0], "doing")
        run("log", tid, "progress", "--by", "Claude", "--sub", 0)
        run("finish", tid, 0, "done it", "--by", "Claude")
        self.assertEqual(subs(tid)[0][0], "done")
        log = run("log-show", tid)["entries"]
        self.assertEqual([e["by"] for e in log], ["Claude"] * len(log))
        self.assertTrue(any("progress" in e["text"] for e in log))

    def test_plan_again_only_adds_whats_missing(self):
        tid = run("plan", "Reused", "--sub", "a")["id"]
        r = run("plan", "Reused", "--sub", "a", "--sub", "b")
        self.assertEqual(r["id"], tid)
        self.assertEqual([t for _, t in subs(tid)], ["a", "b"])

    def test_find(self):
        tid = run("plan", "Findable Thing", "--sub", "x")["id"]
        found = run("find", "findable")
        self.assertIn(tid, [t["id"] for t in found["todos"]])


class Removing(unittest.TestCase):
    """Delete and archive keep everything recoverable."""

    def setUp(self):
        run("folder", "")
        tc.ensure(ROOT)
        self.tid = run("plan", "Doomed " + self._testMethodName, "--sub", "s")["id"]
        run("log", self.tid, "a log line")

    def test_delete_goes_to_the_trash_with_its_log(self):
        run("delete", self.tid)
        self.assertFalse(os.path.exists(todo_file(self.tid)))
        trash = os.path.join(ROOT, ".taskchy", "trash")
        kept = [d for d in os.listdir(trash) if d.endswith(self.tid)]
        self.assertTrue(kept)
        files = os.listdir(os.path.join(trash, kept[0]))
        self.assertIn(self.tid + ".md", files)

    def test_archive_and_back(self):
        run("archive", self.tid)
        self.assertFalse(os.path.exists(todo_file(self.tid)))
        self.assertIn(self.tid, [t["id"] for t in run("list", "--archived")["todos"]])
        run("unarchive", self.tid)
        self.assertTrue(os.path.exists(todo_file(self.tid)))


class Pictures(unittest.TestCase):
    def setUp(self):
        run("folder", "")
        tc.ensure(ROOT)
        self.tid = run("plan", "Pictures", "--sub", "s")["id"]

    def test_add_and_remove(self):
        pic = os.path.join(HOME, "my shot (1).png")
        with open(pic, "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n")
        run("sub-image-add", self.tid, 0, pic)
        im = tc.summary(ROOT, self.tid)["subs"][0]["images"][0]
        self.assertTrue(os.path.isfile(im["file"]))
        self.assertNotIn(" ", os.path.basename(im["file"]))      # a safe file name
        run("sub-image-remove", self.tid, 0, 0)
        self.assertFalse(os.path.exists(im["file"]))
        self.assertTrue(os.path.isfile(pic))                      # your original is untouched

    def test_only_pictures(self):
        doc = os.path.join(HOME, "notes.txt")
        with open(doc, "w") as f:
            f.write("x")
        with self.assertRaises(tc.Fail):
            run("sub-image-add", self.tid, 0, doc)
