"""Native UI qualification; no reducers or authority seeding.

Hybrid policy/runtime qualification explicitly opts into a real Native OMP
coordinator while retaining deterministic terminal workers. It is not provider
worker qualification. Conversation fixture/provider and readiness stay separate.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time
import traceback
from urllib.parse import parse_qs

from owned_runtime import owned_runtime
from product_scenario import (TESTS, UI, instrument, read_json, registry, trace,
                              select_native_dark, window_diagnostics, dismiss_signin)

MODES = {
    'cross_family_review': ('Require review from a different provider family', True, True, 'c2-other-reviewer'),
    'helper_checks': ('Require review; same provider family allowed', True, False, 'c2-same-reviewer'),
    'review_disabled': ('Disable code review; retain all declared checks', False, False, None),
}
RECORDS = (('c2-builder', 'Codex'), ('c2-same-reviewer', 'Codex'),
           ('c2-other-reviewer', 'Claude'), ('c2-release', 'OMP'))
ASSETS = ('mailbox_target.sh', 'mailbox_worker.sh', 'mailbox_json.awk',
          'mailbox_reply.jq', 'mailbox_target.ps1', 'mailbox_worker.ps1', 'setup_argv.ps1',
          'setup_route.sh', 'setup_route.ps1')


def native_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.get('children', []):
            yield from native_nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from native_nodes(child)


def surface_nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.get('c', []):
            yield from surface_nodes(child)


class NativeUI(UI):
    """Only inputs exposed by the real native UI; no hand-built product requests."""
    def __init__(self, runtime, lib, window_key=None):
        super().__init__(runtime, lib)
        self.window_key = window_key
        self.serial = time.time_ns() // 1000
        self.inputs = []
        self.action_map = self.data/('ui-actions-'+str(self.serial)+'.jsonl')

    def record_input(self, value):
        value = {'epoch_ns': time.time_ns(), 'monotonic_ns': time.monotonic_ns(),
                 'window_key': self.window_key, **value}
        self.inputs.append(value)
        with self.action_map.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(value, ensure_ascii=False)+'\n')

    def __call__(self, op, **fields):
        if getattr(self, 'window_key', None) is not None:
            fields['window_key'] = self.window_key
        if op == 'preferences':
            def rendered():
                observed = super(NativeUI, self).__call__(op, **fields)
                return observed if not observed.get('pending') else None
            result = self.lib.wait_for(rendered, 'native preferences surface rendered', self.remaining(30))
        else:
            result = super().__call__(op, **fields)
        if op not in ('surface', 'preferences', 'panes', 'agents', 'context', 'doc_read', 'pane_read'):
            self.record_input({'op': op, 'fields': fields, 'result': result})
        return result

    def choose(self, title, label, observe=None, *, deadline=None):
        operation_deadline = getattr(self, 'operation_deadline', None)
        if operation_deadline is not None:
            deadline = operation_deadline if deadline is None else min(deadline, operation_deadline)
        def title_present(tree):
            return any(isinstance(value, str) and title in value
                       for node in native_nodes(tree.get('tree', [])) for value in node.values())
        def offered():
            tree = self.runtime.ctl('tree')
            if observe is not None:
                observe(tree)
            forms = [pane['pane'] for pane in self('panes')
                     if pane.get('block') == 'orchplus.form' and pane.get('title') == title]
            assert len(forms) <= 1, 'ambiguous native menu '+title
            if forms:
                result = self.machine(forms[0], 'orchplus.form.result', 'form-result')
                return {'form_pane': forms[0]} if result and result.get('phase') == 'editing' else None
            if not (self.runtime.checked_state().get('picker') or {}).get('mode'):
                return None
            if title_present(tree):
                rows = [node for node in native_nodes(tree.get('tree', []))
                        if node.get('role') == 'option' and
                        any(child.get('text') == label for child in native_nodes(node))]
                if len(rows) == 1:
                    return rows[0]
            return None
        budget = self.remaining(40) if deadline is None else min(self.remaining(40), max(0, deadline-time.monotonic()))
        node = self.lib.wait_for(offered, 'native choice '+title+' / '+label, budget)
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError('original native choice deadline expired; no confirmation sent')
        if 'form_pane' in node:
            outer = getattr(self, 'operation_deadline', None)
            self.operation_deadline = deadline
            try:
                return self.mouse_click(node['form_pane'], label)
            finally:
                self.operation_deadline = outer
        # Use the picker's own search and selection, including rows below its
        # clipped viewport. Never infer a selected action from a DOM rectangle.
        self.runtime.ctl('key', 'Ctrl+a')
        self.runtime.ctl('type', json.dumps(label, ensure_ascii=False))
        def selected():
            tree = self.runtime.ctl('tree')
            if observe is not None:
                observe(tree)
            if not title_present(tree):
                return None
            rows = [row for row in native_nodes(tree.get('tree', []))
                    if row.get('role') == 'option' and row.get('aria-selected') == 'true']
            state = self.runtime.checked_state().get('picker') or {}
            # Native state includes the option's secondary description; the
            # clipped DOM may omit it. The exact offered label must be the
            # single remaining search result before Enter is allowed.
            return rows[0] if len(rows) == 1 and state.get('mode') == 'pick' and state.get('query') == label and state.get('rows') == 1 and state.get('selected', '').startswith(label) else None
        budget = self.remaining(40) if deadline is None else min(self.remaining(40), max(0, deadline-time.monotonic()))
        node = self.lib.wait_for(selected, 'exact filtered native choice '+title+' / '+label, budget)
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError('original native choice deadline expired; no confirmation sent')
        answer = self.runtime.ctl('key', 'Enter')
        self.record_input({'op': 'native_picker', 'title': title, 'label': label, 'selection': 'native_search', 'control': node})
        return answer

    def focused_dom(self, pane, tree):
        assert self.runtime.checked_state().get('focused', {}).get('id') == pane, 'native pane focus changed'
        roots = [node for node in native_nodes(tree.get('tree', []))
                 if node.get('tag') == 'section' and {'tn-pane', 'on'} <= set(node.get('class', '').split())]
        # Only click a unique focused native root; layout transitions must settle
        # before choosing a target.
        return roots[0] if len(roots) == 1 else []

    def mouse_click(self, pane, label, *, field_label=None):
        self('focus', pane=pane)
        state = self.runtime.checked_state()
        if any(tab['active'] and tab['zoomed'] for tab in state['tabs']):
            self.runtime.ctl('zoom')
        previous_bounds = None
        def visible():
            nonlocal previous_bounds
            tree = self.runtime.ctl('tree')
            root = self.focused_dom(pane, tree)
            controls = [node for node in native_nodes(root)
                        if (node.get('tag') == 'button' or node.get('role') in ('button', 'combobox', 'option', 'menuitem', 'listitem', 'switch', 'checkbox')
                            or 'sf-act' in node.get('class', '').split())
                        and not node.get('disabled') and node.get('aria-disabled') != 'true'
                        and (node.get('aria-label') == label or any(child.get('text') == label for child in native_nodes(node)))]
            controls = [node for node in controls
                        if not any(other is not node and any(child is other for child in native_nodes(node))
                                   for other in controls)]
            if field_label is not None:
                matches = []
                for parent in native_nodes(root):
                    branch = list(native_nodes(parent))
                    if not any(node.get('text') == field_label for node in branch):
                        continue
                    inside = [node for node in controls if any(child is node for child in branch)]
                    if len(inside) == 1:
                        matches.append((len(branch), inside[0]))
                if not matches:
                    return None
                controls = [min(matches, key=lambda row: row[0])[1]]
            if len(controls) != 1:
                return None
            node = controls[0]
            x, y, width, height = node['rect']
            viewport = self.runtime.checked_state()['viewport']
            if width <= 0 or height <= 0 or not 0 <= x+width/2 < viewport[0]:
                return None
            if y < 45 or y+height >= viewport[1]-10:
                self.runtime.ctl('move', str(x+width/2), str(viewport[1]/2))
                self.runtime.ctl('wheel', '0', str(max(-700, min(700, y-viewport[1]/2))))
                return None
            bounds = tuple(node['rect'])
            if bounds != previous_bounds:
                previous_bounds = bounds
                return None
            return node
        node = self.lib.wait_for(visible, 'visible native mouse control '+label, self.remaining(40))
        x, y, width, height = node['rect']
        if self.remaining(1) <= 0:
            raise TimeoutError('original native click deadline expired; no input sent')
        result = self.runtime.ctl('click', str(x+width/2), str(y+height/2))
        self.record_input({'op': 'native_mouse', 'pane': pane, 'label': label, 'control': node})
        return result

    def edit_field(self, pane, label, value, *, multiline=False):
        """Edit a visible native field; never manufacture a block edit event."""
        operation_deadline = getattr(self, 'operation_deadline', None)
        self('focus', pane=pane)
        previous_bounds = None
        def visible():
            nonlocal previous_bounds
            tree = self.runtime.ctl('tree')
            matches = []
            for parent in native_nodes(self.focused_dom(pane, tree)):
                nodes = list(native_nodes(parent))
                if not any(node.get('text') == label for node in nodes):
                    continue
                controls = [node for node in nodes
                            if node.get('role') == 'textbox'
                            and not node.get('disabled') and node.get('aria-disabled') not in ('true', True)
                            and not node.get('readonly') and node.get('aria-readonly') not in ('true', True)
                            and not {'disabled', 'readonly'} & set(node.get('class', '').split())
                            and all(size > 0 for size in node.get('rect', [0, 0, 0, 0])[2:])]
                if len(controls) == 1:
                    matches.append((len(nodes), controls[0]))
            if not matches:
                return None
            _, node = min(matches, key=lambda row: row[0])
            x, y, width, height = node['rect']
            viewport = self.runtime.checked_state()['viewport']
            if not 0 <= x+width/2 < viewport[0]:
                return None
            if y < 45 or y+height >= viewport[1]-10:
                self.runtime.ctl('move', str(x+width/2), str(viewport[1]/2))
                self.runtime.ctl('wheel', '0', str(max(-700, min(700, y-viewport[1]/2))))
                return None
            bounds = tuple(node['rect'])
            if bounds != previous_bounds:
                previous_bounds = bounds
                return None
            return node
        if '\n' in value and not multiline:
            raise ValueError('single-line native field cannot receive a newline')
        node = self.lib.wait_for(visible, 'visible native field '+label, self.remaining(40))
        def before_input():
            assert self.remaining(1) > 0, 'native field operation deadline expired'
            if operation_deadline is not None and time.monotonic() >= operation_deadline:
                raise TimeoutError('original native field deadline expired; no further input sent')
            assert self.runtime.checked_state().get('focused', {}).get('id') == pane, 'native form focus changed'
        before_input()
        x, y, width, height = node['rect']
        self.record_input({'op': 'native_field_focus', 'pane': pane, 'label': label, 'control': node})
        self.runtime.ctl('click', str(x+width/2), str(y+height/2))
        self.lib.wait_for(lambda: (focused if (focused := visible())
                                  and 'focused' in focused.get('class', '').split() else None),
                          'native text field owns keyboard focus '+label, self.remaining(30))
        before_input()
        self.runtime.ctl('key', 'Ctrl+a')
        if not value:
            before_input()
            self.runtime.ctl('key', 'Backspace')
        for index, line in enumerate(value.split('\n')):
            before_input()
            if index:
                self.runtime.ctl('key', 'Shift+Enter')
            if line:
                self.runtime.ctl('type', json.dumps(line, ensure_ascii=False))
        self.record_input({'op': 'native_field', 'pane': pane, 'label': label, 'value': value, 'control': node})
        def applied():
            surface = self('surface', pane=pane)
            rows = [row for row in surface_nodes(surface.get('main'))
                    if row.get('k') == 'field' and row.get('p', {}).get('label') == label]
            controls = [control for row in rows for control in surface_nodes(row)
                        if control.get('k') in ('input', 'editor')]
            assert len(controls) <= 1, 'ambiguous native text field '+label
            return bool(controls and controls[0].get('p', {}).get('text') == value)
        self.lib.wait_for(applied, 'native program accepted field text '+label, self.remaining(30))

    def select_field(self, pane, label, value):
        """Choose an offered native select option through its rendered control."""
        self('focus', pane=pane)
        def control():
            surface = self('surface', pane=pane)
            fields = [node for node in surface_nodes(surface.get('main'))
                      if node.get('k') == 'field' and node.get('p', {}).get('label') == label]
            assert len(fields) <= 1, 'ambiguous native field '+label
            selects = [node for field in fields for node in surface_nodes(field)
                       if node.get('k') == 'select' and not node.get('p', {}).get('disabled')]
            return selects[0].get('p', {}) if len(selects) == 1 else None
        selected = self.lib.wait_for(control, 'enabled native select '+label, self.remaining(40))
        options = selected.get('options', [])
        offered = [option for option in options if option.get('value') == value and not option.get('disabled')]
        assert len(offered) == 1, 'requested native option is not uniquely available: '+label
        if selected.get('value') == value:
            return
        current = [option for option in options if option.get('value') == selected.get('value')]
        assert len(current) == 1, 'native select has no unique current label'
        self.mouse_click(pane, current[0]['label'], field_label=label)
        def visible_option():
            assert self.runtime.checked_state().get('focused', {}).get('id') == pane, 'native select focus changed'
            tree = self.runtime.ctl('tree')
            rows = [node for node in native_nodes(tree.get('tree', []))
                    if node.get('role') == 'option' and not node.get('disabled')
                    and node.get('aria-disabled') != 'true'
                    and any(child.get('text') == offered[0]['label'] for child in native_nodes(node))
                    and all(size > 0 for size in node.get('rect', [0, 0, 0, 0])[2:])]
            return rows[0] if len(rows) == 1 else None
        node = self.lib.wait_for(visible_option, 'visible native option '+offered[0]['label'], self.remaining(30))
        assert self.remaining(1) > 0, 'native select deadline expired; no option selected'
        x, y, width, height = node['rect']
        self.runtime.ctl('click', str(x+width/2), str(y+height/2))
        self.record_input({'op': 'native_select', 'pane': pane, 'label': label, 'value': value, 'control': node})
        self.lib.wait_for(lambda: (control() or {}).get('value') == value,
                          'native selection applied '+label, self.remaining(30))

    def switch_field(self, pane, label, enabled):
        def control():
            surface = self('surface', pane=pane)
            rows = [node.get('p', {}) for node in surface_nodes(surface.get('main'))
                    if node.get('k') == 'switch' and node.get('p', {}).get('label') == label
                    and not node.get('p', {}).get('disabled')]
            assert len(rows) <= 1, 'ambiguous native switch '+label
            return rows[0] if rows else None
        current = self.lib.wait_for(control, 'enabled native switch '+label, self.remaining(30))
        if current.get('on') != enabled:
            self.mouse_click(pane, label)
        self.lib.wait_for(lambda: (control() or {}).get('on') == enabled,
                          'native switch applied '+label, self.remaining(30))

    def form_pane(self, title):
        def visible():
            matches = [pane['pane'] for pane in self('panes')
                       if pane.get('block') == 'orchplus.form' and pane.get('title') == title]
            assert len(matches) <= 1, 'ambiguous native form '+title
            if not matches:
                return None
            result = self.machine(matches[0], 'orchplus.form.result', 'form-result')
            return matches[0] if result and result.get('phase') == 'editing' else None
        return self.lib.wait_for(visible, 'native form '+title, self.remaining(40))

    def enter(self, title, value, previous='', observe=None, *, deadline=None):
        operation_deadline = getattr(self, 'operation_deadline', None)
        if operation_deadline is not None:
            deadline = operation_deadline if deadline is None else min(deadline, operation_deadline)
        def visible():
            tree = self.runtime.ctl('tree')
            if observe is not None:
                observe(tree)
            return title in json.dumps(tree, ensure_ascii=False)
        budget = self.remaining(40) if deadline is None else min(self.remaining(40), max(0, deadline-time.monotonic()))
        self.lib.wait_for(visible, 'native prompt '+title, budget)
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError('original native prompt deadline expired; no answer entered')
        # Native prompt selects its initial value. Explicit select-all applies to
        # this focused ordinary prompt, never a hidden host settings request.
        if previous:
            self.runtime.ctl('key', 'Ctrl+a')
        if value:
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError('original native prompt deadline expired; no answer entered')
            self.runtime.ctl('type', json.dumps(value, ensure_ascii=False))
        if deadline is not None and time.monotonic() >= deadline:
            raise TimeoutError('original native prompt deadline expired; no answer submitted')
        self.runtime.ctl('key', 'Enter')
        self.record_input({'op': 'native_prompt', 'title': title, 'value': value})

    def prompt(self, label, text):
        return self.enter(label, text)

    def preference(self, pane, row=None, value=None, label=None, page=None):
        dismiss_signin(self.runtime)  # The dialog can appear after startup, before the first text edit.
        self('focus', pane=pane)
        self('preferences', pane=pane)  # Wait for a real owner surface before sending one mutation.
        result = self('preference', pane=pane, row=row, value=value, label=label, page=page)
        if result.get('editing'):
            self.lib.wait_for(lambda: self('preferences', pane=pane)['properties'].get('editing'),
                              'native preference editor', 10)
            # SPAWN's native prefs text editor starts at the end and does not
            # implement select-all. Delete the observed original characters.
            for _ in result.get('previous') or '':
                self.runtime.ctl('key', 'Backspace')
            if value:
                self.runtime.ctl('type', json.dumps(value, ensure_ascii=False))
            self.runtime.ctl('key', 'Enter')
        return result

    def machine(self, pane, role, key=None, *, surface=None):
        tree = surface if surface is not None else self('surface', pane=pane, **({'root': 'main.'+key} if key else {}))
        if tree is None:
            return None
        for node in surface_nodes(tree.get('main')):
            props = node.get('p', {})
            if props.get('role') == role:
                text = props.get('text')
                if text is None:
                    text = ''.join(span if isinstance(span, str) else span.get('t', '')
                                   for span in props.get('spans', []))
                return json.loads(text)
        return None

    def click_match(self, pane, fragment):
        def find():
            tree = self('surface', pane=pane)
            labels = []
            for node in surface_nodes(tree.get('main')):
                props = node.get('p', {})
                if props.get('actions', {}).get('click'):
                    text = props.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                                   for span in props.get('spans', [])))
                    if fragment in text:
                        labels.append(text)
            return labels[0] if len(labels) == 1 else None
        return self.mouse_click(pane, self.lib.wait_for(find, 'unique visible button '+fragment, self.remaining(30)))

    def command(self, pane, name, worker_id=None):
        # Resolve and dispatch the displayed control in one native window callback.
        # Do not retain its event token or pointer position across status redraws.
        def offered():
            tree = self('surface', pane=pane)
            matches = []
            for node in surface_nodes((tree or {}).get('main')):
                props = node.get('p', {})
                attrs = props.get('attrs', {})
                if (props.get('actions', {}).get('click') and not props.get('disabled')
                        and not attrs.get('disabled') and attrs.get('data-orchplus-command') == name
                        and (worker_id is None or attrs.get('data-orchplus-worker') == worker_id)):
                    matches.append(node)
            return matches[0] if len(matches) == 1 else None
        self.lib.wait_for(offered, 'one enabled native command '+name, self.remaining(30))
        return self('click_command', pane=pane, command=name,
                    **({'worker_id': worker_id} if worker_id is not None else {}))

    def agent_picker(self, title):
        """Find the native agent list, including a genuine ready-but-empty state."""
        def visible():
            matches = []
            for pane in self('panes'):
                if pane.get('block') != 'orchplus.form' or pane.get('title') != title:
                    continue
                tree = self('surface', pane=pane['pane'])
                nodes = list(surface_nodes((tree or {}).get('main')))
                selectable = any(node.get('k') == 'item' and node.get('p', {}).get('key', '').startswith('choice:')
                                 and not node.get('p', {}).get('disabled') for node in nodes)
                empty = any((node.get('p', {}).get('text') or ''.join(
                    span if isinstance(span, str) else span.get('t', '')
                    for span in node.get('p', {}).get('spans', []))).startswith('No eligible agents.')
                    for node in nodes)
                if empty or selectable:
                    matches.append(pane['pane'])
            assert len(matches) <= 1, 'ambiguous native agent picker'
            return matches[0] if matches else None
        return self.lib.wait_for(visible, 'loaded compact agent picker '+title, self.remaining(40))

    def pick_agent(self, title, label):
        pane = self.agent_picker(title)
        def offered():
            tree = self('surface', pane=pane)
            rows = [node['p']['label'] for node in surface_nodes((tree or {}).get('main'))
                    if node.get('k') == 'item' and not node.get('p', {}).get('disabled')
                    and (node.get('p', {}).get('label') == label or node.get('p', {}).get('label', '').startswith(label+' — '))]
            assert len(rows) <= 1, 'ambiguous available agent '+label
            return rows[0] if rows else None
        actual = self.lib.wait_for(offered, 'available native agent '+label, self.remaining(40))
        return self.mouse_click(pane, actual)

    def question_click(self, pane, question, label='Review decision…'):
        """Click the rendered question's own button, never synthesize its intent."""
        self('focus', pane=pane)
        # Native tree text is clipped; the full gate identity is checked before input.
        visible_question = question[:160]
        def offered():
            choices = []
            for parent in native_nodes(self.focused_dom(pane, self.runtime.ctl('tree'))):
                nodes = list(native_nodes(parent))
                if not any(visible_question in node.get('text', '') for node in nodes):
                    continue
                buttons = [node for node in nodes
                           if (node.get('role') == 'button' or node.get('tag') == 'button')
                           and any(child.get('text') == label for child in native_nodes(node))]
                if len(buttons) == 1:
                    choices.append((len(nodes), buttons[0]))
            if not choices:
                return None
            controls = {tuple(node['rect']): node for _, node in choices}
            assert len(controls) == 1, 'ambiguous visible owner question'
            node = next(iter(controls.values()))
            x, y, width, height = node['rect']
            viewport = self.runtime.checked_state()['viewport']
            if y < 45 or y+height >= viewport[1]-10:
                self.runtime.ctl('move', str(x+width/2), str(viewport[1]/2))
                self.runtime.ctl('wheel', '0', str(max(-700, min(700, y-viewport[1]/2))))
                return None
            return node
        node = self.lib.wait_for(offered, 'visible exact owner question', self.remaining(40))
        assert self.remaining(1) > 0, 'owner question deadline expired'
        x, y, width, height = node['rect']
        result = self.runtime.ctl('click', str(x+width/2), str(y+height/2))
        self.record_input({'op': 'native_question', 'pane': pane, 'question': question, 'control': node})
        return result

    def conversation_input(self, pane, text):
        """Send a real user turn only through an idle native agent's composer."""
        def idle():
            agents = self('agents')
            if any(agent['state'] == 'waiting_input' for agent in agents):
                return None
            rows = [agent for agent in agents if agent['pane'] == pane]
            assert len(rows) <= 1, 'ambiguous native conversation identity'
            if rows:
                assert not rows[0].get('delivery_error'), rows[0].get('delivery_error')
            return rows[0] if rows and rows[0]['state'] == 'idle' else None
        self.lib.wait_for(idle, 'native conversation idle; permission prompts remain unanswered', self.remaining(120))
        self('focus', pane=pane)
        def composer():
            if not idle():
                return None
            assert self.runtime.ctl('state').get('focused', {}).get('id') == pane, 'native conversation focus changed'
            panes = [node for node in native_nodes(self.runtime.ctl('tree').get('tree', []))
                     if node.get('tag') == 'section'
                     and {'tn-pane', 'agent', 'on'} <= set(node.get('class', '').split())]
            assert len(panes) <= 1, 'ambiguous focused native agent pane'
            # Tern also exposes the terminal's hidden backing textarea. Type only
            # into the visible native agent editor in the verified focused pane.
            controls = [node for node in native_nodes(panes[0] if panes else [])
                        if node.get('role') == 'textbox' and 'sf-editor' in node.get('class', '').split()
                        and not node.get('disabled') and all(size > 0 for size in node.get('rect', [0, 0, 0, 0])[2:])]
            assert len(controls) <= 1, 'ambiguous native conversation composer'
            return controls[0] if controls else None
        node = self.lib.wait_for(composer, 'visible native conversation composer', self.remaining(40))
        assert self.remaining(1) > 0 and idle(), 'native input deadline/state changed'
        x, y, width, height = node['rect']
        self.runtime.ctl('click', str(x+width/2), str(y+height/2))
        # ctl type turns a literal newline into Enter, which submits a partial
        # native agent turn. Insert multiline breaks with the editor shortcut.
        for index, line in enumerate(text.split('\n')):
            if index:
                self.runtime.ctl('key', 'Shift+Enter')
            if line:
                self.runtime.ctl('type', json.dumps(line, ensure_ascii=False))
        assert self.remaining(1) > 0 and idle(), 'native submit deadline/state changed'
        self.runtime.ctl('key', 'Enter')
        self.record_input({'op': 'native_conversation_input', 'pane': pane, 'text': text, 'control': node})


def assignment_refusal(product, emitted, response):
    """Bind a refused queue receipt to this exact native control and submission."""
    events = trace(product.runtime, 'orchplus')['events']
    token = emitted['event'].split('=', 1)[1]
    clicks = [(index, event['data']) for index, event in enumerate(events)
              if event['kind'] == 'assignment_intent'
              and event['data'].get('pane') == product.controller
              and event['data'].get('control_token') == token]
    if not clicks:
        return None
    assert len(clicks) == 1, 'ambiguous native assignment control'
    index, click = clicks[0]
    submitted = [event['data'] for event in events[index+1:]
                 if event['kind'] == 'assignment_submission'
                 and event['data'].get('pane') == product.controller
                 and event['data'].get('request_id') == response['request_id']]
    if not submitted:
        return None
    assert len(submitted) == 1, 'ambiguous native assignment submission'
    request = submitted[0]
    assert click.get('namespace_matches') is True and all(request.get(key) is True for key in
        ('namespace_matches', 'origin_pane_matches', 'origin_alias_matches')), 'assignment origin changed'
    assert all(request.get(key) == click.get(key) for key in
        ('expected_revision', 'record_id')), 'refusal belongs to another captured assignment'
    return {'control': click, 'submission': request, 'response': response}


def owner_setup_input(product, *, complete, unchanged, deadline, command=None, label=None, worker_id=None, interaction=None):
    """One current native setup click; one fresh click only after a proved stale refusal.

    The isolated fixture is the sole setup-control actor. Background bridge
    observations can also publish operator results, so unrelated outcomes do not
    establish completion or refusal. Correlation requires the exact emitted
    control, unchanged native source identity and a new matching operator outcome,
    or a newly visible stale-control refusal with that control now absent.
    Assignment forms use their separately approved complete native interaction.
    Document writes and other confirmations/approvals never enter this helper.
    """
    allowed_commands = {'pause', 'resume', 'associate_document', 'catalog', 'close_session'}
    allowed_labels = {'Register a distinct logical session…', 'Claim controller in this pane'}
    assert (command in allowed_commands and label is None and interaction is None or
            label in allowed_labels and command is None and interaction is None or
            command == 'queue' and label is None and callable(interaction)), 'not an approved fresh owner interaction'
    ui = product.ui
    assert getattr(ui, 'operation_deadline', None) is None, 'owner interactions must be serial, not nested'
    ledger = product.runtime.root/'owner-setup-inputs.jsonl'
    product.result['owner_setup_input_ledger'] = str(ledger)
    counts = product.result.setdefault('owner_setup_input_counts', {
        'submitted': 0, 'refused': 0, 'fresh_interactions': 0, 'completed': 0, 'failed': 0})
    step = command or label
    step_id = time.monotonic_ns()

    def record(phase, **fields):
        with ledger.open('a', encoding='utf-8') as stream:
            stream.write(json.dumps({'step_id': step_id, 'step': step, 'phase': phase,
                'monotonic_ns': time.monotonic_ns(), 'original_deadline': deadline,
                'window_key': ui.window_key, 'pane': product.controller, **fields},
                ensure_ascii=False)+'\n')

    def observe():
        tree = ui('surface', pane=product.controller)
        assert tree and tree.get('main'), 'native setup surface is unavailable'
        dispatch = ui.machine(product.controller, 'orchplus.dispatch', surface=tree) or {}
        alias = ui.machine(product.controller, 'orchplus.alias', surface=tree) or {}
        intent = ui.machine(product.controller, 'orchplus.intent', surface=tree)
        refusals, controls = [], []
        for node in surface_nodes(tree['main']):
            props = node.get('p', {})
            text = props.get('text', ''.join(
                span if isinstance(span, str) else span.get('t', '') for span in props.get('spans', [])))
            if text.startswith('REFUSED:'):
                refusals.append(text)
            action = props.get('actions', {}).get('click')
            if action:
                controls.append(action)
        return {'alias': alias, 'command_result': dispatch.get('command_result'),
                'intent': intent, 'refusals': refusals, 'controls': controls,
                'authority_revision': dispatch.get('authority_revision', alias.get('revision')),
                'tree': tree}

    def retained(observed):
        return {key: value for key, value in observed.items() if key not in ('tree', 'controls')}

    ui.operation_deadline = deadline
    last = None
    try:
        for attempt in (1, 2):
            before = observe()
            assert before['intent'] is None, 'another owner intent remains unresolved'
            before_state = registry(product.runtime)
            assert all(isinstance(before['alias'].get(key), str) and before['alias'][key]
                       for key in ('alias_nonce', 'authority_namespace')), 'native source identity is missing'
            assert not complete(before, before_state), 'setup postcondition already held before this interaction'
            record('before_input', attempt=attempt, observed=retained(before))
            emitted = (interaction() if interaction is not None else
                       ui.command(product.controller, command, worker_id=worker_id) if command
                       else ui.click(product.controller, label))
            assert isinstance(emitted, dict) and emitted.get('event', '').startswith('control='), 'no exact native control receipt'
            counts['submitted'] += 1
            if attempt == 2:
                counts['fresh_interactions'] += 1
            record('submitted', attempt=attempt, emitted=emitted)
            accepted_request, seen_intent = None, None

            def outcome():
                nonlocal last, accepted_request, seen_intent
                last = observe()
                current = registry(product.runtime)
                previous = before['command_result'] or {}
                response = last['command_result'] or {}
                same_source = all(last['alias'].get(key) == before['alias'].get(key)
                                  for key in ('alias_nonce', 'authority_namespace', 'orch_session_id'))
                matched = (same_source and command and response.get('command') == command
                           and isinstance(response.get('request_id'), str)
                           and response['request_id'] != previous.get('request_id'))
                if matched and response.get('ok') is True:
                    accepted_request = response['request_id']
                intent = last['intent']
                if intent and intent.get('serial') != seen_intent:
                    seen_intent = intent.get('serial')
                    record('observed_intent', attempt=attempt, intent=intent)
                completed = complete(last, current)
                if completed and (command not in {'pause', 'resume', 'catalog'} or accepted_request):
                    return ('completed', completed)
                refused = matched and response.get('ok') is False
                assignment_evidence = None
                if refused and command == 'queue':
                    assignment_evidence = assignment_refusal(product, emitted, response)
                    if assignment_evidence is None:
                        return None  # Private trace flush may lag; absence never permits another input.
                stale_notice = any(
                    text not in before['refusals'] and text.startswith((
                        'REFUSED: the displayed action is stale and this controller slot is occupied by ',
                        'REFUSED: this displayed action expired after the view changed.'))
                    for text in last['refusals'])
                expired_control = (same_source and stale_notice
                                   and emitted['event'] not in last['controls']
                                   and response == previous)
                if not refused and not expired_control:
                    return None
                record('refusal', attempt=attempt, emitted=emitted, observed=retained(last),
                       assignment_evidence=assignment_evidence)
                counts['refused'] += 1
                assert not accepted_request and last['intent'] is None, 'owner effect is accepted or still pending; no fresh input'
                assert unchanged(before_state, current), 'target effect changed; refusal is not pre-effect proof'
                assert (response.get('code') == 'stale_revision' and refused
                        if command == 'queue' else expired_control or response.get('code') == 'stale_revision'), 'not a positively identified stale refusal'
                return ('refused', response if refused else last['refusals'])

            kind, value = product.lib.wait_for(outcome, 'native setup '+step, ui.remaining(40), .05)
            if kind == 'completed':
                counts['completed'] += 1
                record('completed', attempt=attempt, observed=retained(last))
                return value
            assert attempt == 1, 'second native setup interaction refused; no further input permitted'
            record('fresh_interaction_permitted', refusal=value, remaining_seconds=ui.remaining(40))
        raise AssertionError('native setup did not complete')
    except Exception as error:
        counts['failed'] += 1
        record('failed', error=f'{type(error).__name__}: {error}',
               observed=retained(last) if last else None)
        raise
    finally:
        ui.operation_deadline = None


def provider_prerequisite(args, *, coordinator=False):
    """Validate explicit consent before creating a runtime or touching accounts."""
    if coordinator and not getattr(args, 'provider_coordinator', False):
        return {'status': 'unavailable', 'reason': 'This hybrid scenario requires explicit --provider-coordinator --provider-agent-dir /absolute/approved/agent-dir; ordinary local-terminal records cannot coordinate. No provider calls were started.'}
    directory = getattr(args, 'provider_agent_dir', None)
    if (directory is None or not Path(directory).is_absolute()
            or not Path(directory).is_dir() or not shutil.which('omp')):
        return {'status': 'unavailable', 'reason': 'Provider usage requires installed OMP and --provider-agent-dir naming an approved absolute existing directory, used in place without reading or copying credentials.'}
    return None


def provider_coordinator_identity(product, worker):
    """Bind genuine native observations to this exact saved worker incarnation."""
    selected, = [row for row in saved_records(product.runtime) if row['id'] == worker['record_id']]
    assert selected['backend'] == 'native-agent'
    assert 'coordinator-control-v1' in selected['mailbox']['capabilities']
    assert 'coordinator-control-v1' in worker['capabilities']
    assert worker['phase'] == 'accepted' and worker.get('pane_binding')
    native, = [row for row in product.ui('agents')
               if str(row['pane']) == str(worker['pane_binding']['pane_id'])]
    assert not native.get('delivery_error'), native.get('delivery_error')
    model = 'openai-codex/gpt-6-astra'
    directory = product.runtime.root/'provider-sessions'/worker['record_id']
    argv = shlex.split(native['command'])
    assert argv.count('--model') == 1 and argv[argv.index('--model')+1] == model
    assert argv.count('--session-dir') == 1 and Path(argv[argv.index('--session-dir')+1]) == directory
    proof = {'native_agent': native, 'saved_record': selected,
             'provider_identity': provider_session_identity(directory, model, worker)}
    product.result.setdefault('hybrid_coordinator_identity', {})[worker['worker_id']] = proof
    return proof


def provider_coordinator_prompt(product, worker, text, *, deadline):
    """One literal user turn, never a permission answer or producer-file write."""
    ui, outer = product.ui, getattr(product.ui, 'operation_deadline', None)
    ui.operation_deadline = min(outer, deadline) if outer else deadline
    try:
        assert product.provider or product.provider_coordinator, 'provider consent required'
        current = registry(product.runtime)['dispatch']['workers'][worker['worker_id']]
        assert current['worker_generation'] == worker['worker_generation']
        identity = provider_coordinator_identity(product, current)
        session_file = Path(identity['provider_identity']['session_file'])
        def user_turns():
            turns = {}
            for line in session_file.read_bytes().splitlines(keepends=True):
                if not line.endswith(b'\n'):
                    continue
                row = json.loads(line)
                message = row.get('message', {})
                if row.get('type') != 'message' or message.get('role') != 'user':
                    continue
                content = message['content']
                turns[row['id']] = content if isinstance(content, str) else '\n'.join(
                    part['text'] for part in content if part.get('type') == 'text')
            return turns
        before = set(user_turns())
        ui.conversation_input(int(current['pane_binding']['pane_id']), text)
        def delivered():
            matches = [key for key, body in user_turns().items() if key not in before and body == text]
            assert len(matches) <= 1, 'native conversation submitted the same user turn twice'
            return matches[0] if matches else None
        message_id = product.lib.wait_for(delivered, 'one exact native user turn',
                                         max(0, deadline-time.monotonic()), .1)
        product.result.setdefault('coordinator_user_turns', []).append({
            'worker_id': current['worker_id'], 'worker_generation': current['worker_generation'],
            'native_message_id': message_id, 'exact_native_user_turn': True,
            'text': text, 'route': 'literal native conversation composer; no automatic native permission answers'})
    finally:
        ui.operation_deadline = outer


def ensure_fixture_coordinator(product, *, deadline):
    """Real Native OMP coordinator and consumed activation before launch faults."""
    unavailable = provider_prerequisite(product.args, coordinator=not product.provider)
    assert not unavailable, unavailable
    ui, outer = product.ui, getattr(product.ui, 'operation_deadline', None)
    ui.operation_deadline = min(outer, deadline) if outer else deadline
    try:
        ui('focus', pane=product.controller)
        scope = ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
        sid = scope['orch_session_id']
        state = registry(product.runtime)
        existing = [row for row in state['dispatch']['workers'].values()
                    if row['logical_session_id'] == sid and row.get('role') == 'coordinator'
                    and not row.get('mailbox_retired')]
        assert len(existing) <= 1, 'ambiguous active fixture coordinator'
        if not existing:
            if not any(row['id'] == 'c2-coordinator' for row in saved_records(product.runtime)):
                product.open_spawn()
                product.create_record('c2-coordinator', 'OMP', coordinator=True)
            owner_assignment(product, 'c2-coordinator', (), deadline=deadline, coordinator=True)
        def activated():
            workers = registry(product.runtime)['dispatch']['workers'].values()
            rows = [row for row in workers if row['logical_session_id'] == sid
                    and row.get('role') == 'coordinator' and not row.get('mailbox_retired')]
            if (len(rows) != 1 or rows[0]['phase'] != 'accepted' or not rows[0].get('mailbox_handle')
                    or not rows[0].get('pane_binding')
                    or not rows[0].get('activation', {}).get('acknowledged')):
                return None
            return rows[0]
        worker = product.lib.wait_for(activated, 'genuine coordinator activation ACK accepted', ui.remaining(180))
        provider_coordinator_identity(product, worker)
        product.result.setdefault('hybrid_coordinator_activation', {})[worker['worker_id']] = worker['activation']
        return worker
    finally:
        ui.operation_deadline = outer


def answer_owner_gate(product, gate, choice_id='approve', answer='Approve only this exact disposable qualification decision.'):
    """One answer to the observed revision through its visible question card."""
    ui = product.ui
    scope = ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
    assert scope and scope.get('controller_phase') == 'active'
    origin = (scope.get('command_cursor') or {}).get('origin')
    assert origin, 'owner decision lacks current native controller origin'
    current = registry(product.runtime)['dispatch']['gates'][gate['id']]
    assert all(current.get(key) == gate.get(key) for key in
               ('id', 'revision', 'worker_id', 'worker_generation', 'question', 'options'))
    assert current['phase'] == 'pending'
    ui.question_click(product.controller, gate['question'])
    choice, = [option for option in gate['options'] if option['id'] == choice_id]
    ui.choose(gate['question'][:160], choice['label'])
    # Coordinator proposals and landing are ordinary non-host questions.
    ui.enter('Explicit owner answer for '+gate['id'], answer)
    def saved():
        current = registry(product.runtime)['dispatch']['gates'][gate['id']]
        assert current['revision'] == gate['revision'], 'question changed while answering'
        observed = current.get('answer')
        if observed:
            assert observed['choice_id'] == choice_id and observed['source']['kind'] == 'owner'
            assert all(observed['source'].get(key) == value for key, value in origin.items()), 'owner decision came from a different native origin'
            return current
        return None
    return product.lib.wait_for(saved, 'exact native owner answer committed', ui.remaining(40))


def owner_assignment(product, record, fields, *, deadline, coordinator=False):
    """Actual coordinator proposal → owner review → held work → explicit START."""
    ui, outer = product.ui, getattr(product.ui, 'operation_deadline', None)
    ui.operation_deadline = min(outer, deadline) if outer else deadline
    try:
        project = product.current_project()
        sid = project['logical_session_id']
        known = set(registry(product.runtime)['dispatch']['workers'])
        if coordinator:
            selected, = [row for row in saved_records(product.runtime) if row['id'] == record]
            assert selected['backend'] == 'native-agent', 'ordinary terminal records cannot coordinate'
            assert product.provider or product.provider_coordinator, 'provider coordinator requires explicit consent'
            ui.command(product.controller, 'start_orchestrator')
            ui.choose('Existing orchestrated project or New', project['name'])
            ui.pick_agent('Choose your orchestrator', product.record_label(record))
        else:
            source = ensure_fixture_coordinator(product, deadline=deadline)
            project = product.current_project()
            if not project.get('repository'):
                product.configure_repository(product.repository)
            values = dict(fields)
            prompt = next(value for label, value in fields if label.startswith('Explicit assignment'))
            checks = []
            for line in next((value for label, value in fields if label.startswith('Checks')), '').splitlines():
                if line.strip():
                    check_id, separator, command = line.partition(':')
                    assert separator, 'declared check requires id: argv'
                    checks.append({'check_id': check_id.strip(), 'argv': shlex.split(command)})
            catalog = registry(product.runtime)['dispatch']['catalogs'][sid]
            selected, = [row for row in catalog['records'] if row['id'] == record]
            proposal_id = 'native-task-'+str(time.time_ns())
            payload = {'proposal_id': proposal_id, 'kind': 'new_work',
                       'record_id': record, 'record_revision': selected['revision'], 'prompt': prompt,
                       'orch_project_id': project['orch_project_id'],
                       'scope': {'paths': [value.strip() for value in values.get('Declared files', '').split(',') if value.strip()], 'systems': []},
                       'checks': checks}
            if values.get('Base ref'):
                payload['base_ref'] = values['Base ref']
            worker_command(product, source['mailbox_handle'], 'propose-task', payload)
            def pending():
                for gate in registry(product.runtime)['dispatch']['gates'].values():
                    if gate.get('kind') != 'coordinator_proposal' or gate.get('worker_id') != source['worker_id']:
                        continue
                    proposal = json.loads(gate['proposal'])
                    if proposal['payload'].get('proposal_id') == proposal_id:
                        assert proposal['payload'] == dict(payload, owner_id=source['coordinator_owner_id'],
                            owner_generation=source['coordinator_generation'],
                            activation_token=source['activation']['activation_token']), 'provider changed requested proposal'
                        assert gate['worker_generation'] == source['worker_generation']
                        assert gate['phase'] == 'pending', 'proposal did not require the native owner'
                        return gate
                return None
            gate = product.lib.wait_for(pending, 'actual producer proposal reaches native owner', ui.remaining(60))
            answer_owner_gate(product, gate)
        def created():
            rows = [row for key, row in registry(product.runtime)['dispatch']['workers'].items()
                    if key not in known and row['record_id'] == record and row['logical_session_id'] == sid]
            assert len(rows) <= 1, 'one native decision created multiple workers'
            return rows[0] if rows else None
        worker = product.lib.wait_for(created, 'native task admission', ui.remaining(40))
        if coordinator:
            def activated():
                current = registry(product.runtime)['dispatch']['workers'][worker['worker_id']]
                return current if (current['phase'] == 'accepted' and current.get('pane_binding')
                                   and current.get('activation', {}).get('acknowledged')) else None
            worker = product.lib.wait_for(activated, 'actual Native OMP acceptance and activation ACK', ui.remaining(180))
            provider_coordinator_identity(product, worker)
            if any(value for _, value in fields):
                provider_coordinator_prompt(product, worker, '\n\n'.join(
                    value for _, value in fields if value), deadline=deadline)
        if not coordinator:
            assert worker.get('project_held'), 'proposal skipped held-work boundary'
            project = product.current_project()
            ui.command(product.controller, 'project_menu')
            ui.choose(project['name'], "START this project's held work")
            if project.get('checks_pending'):
                ui.choose('Review declared checks for '+project['name'], 'START this project with these checks')
            def started():
                current = registry(product.runtime)['dispatch']['workers'][worker['worker_id']]
                return current if not current.get('project_held') and not current.get('checks_pending') else None
            worker = product.lib.wait_for(started, 'explicit reviewed project START', ui.remaining(40))
        return worker
    finally:
        ui.operation_deadline = outer


def spawn_authority(runtime):
    return (read_json(runtime.config/'plugin-data/spawn/kv.json') or {}).get('authority')


def saved_records(runtime):
    authority = spawn_authority(runtime)
    return authority['config']['hosts'][authority['host_key']]['agents'] if authority else []


def git(runtime, repository, *args):
    result = subprocess.run(['git', '-C', str(repository), *args], env=runtime.env,
                            check=True, capture_output=True, text=True, timeout=20)
    return result.stdout.strip()


class Product:
    def __init__(self, base, root, evidence, processes, lib, name, args, provider=False, instrumented=True, assignment_trace=False):
        self.lib, self.root, self.args, self.provider = lib, root, args, provider
        self.provider_coordinator = bool(getattr(args, 'provider_coordinator', False)) and not provider and name != 'conversation-journey-fixture'
        if provider or self.provider_coordinator:
            unavailable = provider_prerequisite(args, coordinator=self.provider_coordinator)
            if unavailable:
                raise ValueError(unavailable['reason'])
        self.instrumented = instrumented and not provider
        self.runtime = runtime = owned_runtime(lib, base, name, evidence, processes,
                                               capture_desktop=args.capture_desktop,
                                               provider_agent_dir=args.provider_agent_dir if provider or self.provider_coordinator else None)
        self.result = {'status': 'failed', 'source': str(root), 'route': 'ordinary native SPAWN/ORCH entrypoints; no seeded authorities',
                       'worker_kind': 'deterministic managed local-terminal fixture, not provider-backed task proof',
                       'checks': [], 'captures': {}, 'limits': ['Linux owned desktop only',
                       'No provider credentials copied or provider workers launched by this harness',
                       'Native pixel captures require separate visual inspection for final media'],
                       'endpoints': {'config': str(runtime.config), 'daemon_socket': str(runtime.sock),
                                     'control_socket': str(runtime.control), 'logs': str(runtime.logs)}}
        if self.provider_coordinator:
            self.result.update(
                worker_kind='hybrid: genuine Native OMP coordinator; deterministic managed local-terminal task workers',
                qualification_scope='controlled worker/check/recovery scenarios, NOT genuine-provider-worker qualification',
                explicit_provider_coordinator_consent=True, automatic_native_permission_answers=False)
            self.result['limits'][1] = 'Bounded approved Native OMP coordinator calls only; authentication used in place, no credential copies or native permission answers'
        if provider:
            self.result['worker_kind'] = 'actual approved native OMP/provider workers; authentication used in place'
            self.result['limits'][1] = 'Explicit provider mode: existing authenticated accounts only; no credential copies, new accounts, unsafe approval flags or automatic native permission answers'
            self.result['provider_models'] = {'builder': 'openai-codex/gpt-6-astra',
                                              'same_family_reviewer': 'openai-codex/gpt-6-astra',
                                              'other_family_reviewer': 'anthropic/claude-opus-5-5',
                                              'release_manager': 'openai-codex/gpt-6-astra'}
        self.repository = runtime.root/'repository'
        self.repository.mkdir()
        for parts in (('init', '-q', '-b', 'main'), ('config', 'user.name', 'C2 deterministic fixture'),
                      ('config', 'user.email', 'c2-fixture@example.invalid')):
            git(runtime, self.repository, *parts)
        (self.repository/'fixture.txt').write_text('good\n')
        git(runtime, self.repository, 'add', 'fixture.txt')
        git(runtime, self.repository, 'commit', '-q', '-m', 'Disposable C2 root')
        self.control = runtime.root/'worker-control'
        self.control.mkdir()
        packages = runtime.root/'product-packages'
        packages.mkdir()
        self.spawn, self.orch = packages/'SPAWN', packages/'ORCH+'
        if not self.instrumented:
            shutil.copytree(root/'plugins/tern/SPAWN', self.spawn)
            shutil.copytree(root/'plugins/tern/ORCH+', self.orch)
            self.result['package_instrumentation'] = 'none; exact source packages'
        else:
            # Observational wrappers only; C1 record injection is not enabled.
            instrument(root/'plugins/tern/SPAWN', self.spawn,
                       {'orch_kv': str(runtime.config/'plugin-data/orchplus/kv.json')})
            instrument(root/'plugins/tern/ORCH+', self.orch,
                       {'assignment_trace': assignment_trace or bool(getattr(args, 'assignment_trace', False)), 'toast_trace': True})
            self.result['package_instrumentation'] = 'observational entrypoint wrappers; not byte-identical final-package capture'
        self.worker = packages/'policy_worker.py'
        shutil.copy2(TESTS/'policy_worker.py', self.worker)
        driver = packages/'driver'
        driver.mkdir()
        shutil.copy2(TESTS/'product_driver.luau', driver/'window.luau')
        (driver/'plugin.toml').write_text('schema = 1\nid = "report-product-driver"\nname = "Native product UI driver"\nversion = "0.1.0"\nwindow = "window.luau"\n')
        self.driver = driver
        self.result['fixture_sources'] = {str(path.relative_to(TESTS)): hashlib.sha256(path.read_bytes()).hexdigest()
                                          for path in (TESTS/'policy_worker.py', TESTS/'product_driver.luau', TESTS/'product_probe.luau',
                                                       TESTS/'product_c2.py', TESTS/'owned_runtime.py', TESTS/'owned_window.py')}
        self.result['disposable_repository'] = str(self.repository)

    def start(self, installed=False):
        runtime = self.runtime
        runtime.start()
        for package in (self.spawn, self.orch, self.driver):
            runtime.command('plugin', 'install' if package != self.driver and (installed or not self.instrumented) else 'link', package)
        self.ui = NativeUI(runtime, self.lib)
        if not self.instrumented:
            installed_root = Path(json.loads(runtime.command('plugin', 'dir', '--json'))['dir'])
            def hashes(directory):
                return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in sorted(directory.rglob('*')) if path.is_file()}
            self.result['installed_package_provenance'] = {}
            for name, plugin_id, copied in (('SPAWN', 'spawn', self.spawn), ('ORCH+', 'orchplus', self.orch)):
                expected = hashes(self.root/'plugins/tern'/name)
                assert hashes(copied) == expected, 'provider copy differs from product source: '+name
                assert hashes(installed_root/plugin_id) == expected, 'native installed package differs from product source: '+name
                self.result['installed_package_provenance'][plugin_id] = {
                    'files': len(expected), 'installed': str(installed_root/plugin_id),
                    'manifest_sha256': hashlib.sha256(json.dumps(expected, sort_keys=True).encode()).hexdigest()}
        if self.args.capture_desktop:
            self.result['native_capture_controls'] = [
                {'command': list(command), 'response': runtime.ctl(*command)}
                for command in (('size', '1920', '1080'), ('font', '17'), ('ui-font-size', '17'))]
        dismiss_signin(runtime)
        for command in (('theme', 'dark', 'obsidian'), ('appearance', 'dark'), ('style', 'solid')):
            runtime.ctl(*command)
        self.result['native_dark_selection'] = select_native_dark(runtime)
        self.result['owned_environment'] = runtime.owned_environment
        self.result['native_context'] = self.ui('context')
        self.metadata('started')
        if self.args.capture_start_hold:
            self.metadata('capture-start-hold')
            deadline = time.monotonic()+self.args.capture_start_hold
            while time.monotonic() < deadline and not (runtime.root/'capture-start-release').exists():
                runtime.checked_state()
                self.lib.idle(.5)

    def metadata(self, phase):
        runtime = self.runtime
        value = {'schema': 1, 'phase': phase, 'pid': os.getpid(), 'runtime_root': str(runtime.root),
                 'endpoints': self.result['endpoints'], 'owned_environment': runtime.owned_environment,
                 'display': read_json(runtime.capture_metadata) if hasattr(runtime, 'capture_metadata') else None,
                 'action_map': str(self.ui.action_map), 'capture_epoch_ns': time.time_ns(),
                 'command_file': str(self.ui.data/'command.json'), 'response_file': str(self.ui.data/'response.json'),
                 'command_protocol': {'id': 'unique integer < 2^53', 'op': 'open|focus|close|surface|click|click_gate|click_command|preferences|preference|panes|agents|context|doc_open|doc_read|doc_edit|pane_read',
                                      'window_key': 'optional exact native key for multiwindow routing'},
                 'native_action_command': ['tern', 'ctl', '--control', str(runtime.control), 'plugins', 'run', 'ACTION'],
                 'input_rule': 'C2 uses only visible buttons/preferences and ordinary registered actions; event/settings are not C2 inputs',
                 'release_file': str(runtime.root/'capture-release'), 'deadline_seconds': self.args.capture_hold,
                 'start_release_file': str(runtime.root/'capture-start-release'),
                 'start_deadline_seconds': self.args.capture_start_hold,
                 'provider_readiness_action': 'plugin.orchplus.orch_readiness',
                 'provider_prerequisites': 'explicitly approved existing authentication used in place' if self.provider or self.provider_coordinator else 'private HOME contains no provider authentication; provider mode is separate'}
        path = runtime.root/'interactive-control.json'
        path.write_text(json.dumps(value, indent=2)+'\n')
        self.result['interactive_control'] = str(path)
        if self.args.control_metadata:
            self.args.control_metadata.parent.mkdir(parents=True, exist_ok=True)
            self.args.control_metadata.write_text(json.dumps(value, indent=2)+'\n')

    def capture(self, label):
        self.result['captures'][label] = window_diagnostics(self.runtime, label)
        self.metadata(label)

    def hold(self):
        if getattr(self, '_capture_hold_started', False):
            return
        self._capture_hold_started = True
        if self.args.capture_hold:
            self.metadata('capture-hold')
            deadline = time.monotonic()+self.args.capture_hold
            while time.monotonic() < deadline and not (self.runtime.root/'capture-release').exists():
                self.runtime.checked_state()
                self.lib.idle(.5)

    def close(self):
        if self.result.get('error'):
            for label, pane in (('spawn', getattr(self, 'spawn_pane', None)),
                                ('orch', getattr(self, 'controller', None))):
                if pane is None:
                    continue
                try:
                    self.result['failure_'+label+'_surface'] = self.ui('surface', pane=pane)
                except Exception as error:
                    self.result['failure_'+label+'_surface_error'] = str(error)
        self.result['orch_authority'] = registry(self.runtime)
        self.result['spawn_authority'] = spawn_authority(self.runtime)
        self.result['inputs'] = getattr(getattr(self, 'ui', None), 'inputs', [])
        if self.instrumented:
            self.result['traces'] = {plugin+'/'+realm: trace(self.runtime, plugin, realm)
                                     for plugin in ('spawn', 'orchplus') for realm in ('host', 'window')}
        (self.control/'stop').write_text('owned supervisor cleanup\n')
        for wake in getattr(self, 'extra_wakers', []):
            if wake in self.lib.WAKERS:
                self.lib.WAKERS.remove(wake)
        self.runtime.stop()

    def open_spawn(self):
        existing = [candidate['pane'] for candidate in self.ui('panes')
                    if candidate.get('block') == 'spawn.spawner']
        assert len(existing) <= 1, 'ambiguous SPAWN setup pane'
        if existing:
            self.ui('focus', pane=existing[0])
            if self.ui('preferences', pane=existing[0])['properties'].get('page') != 'managed':
                self.ui.preference(existing[0], page='managed')
        else:
            self.ui('action', action='plugin.spawn.spawn_managed_setup')
        def pane():
            matches = [candidate['pane'] for candidate in self.ui('panes')
                       if candidate.get('block') == 'spawn.spawner']
            assert len(matches) <= 1, 'ambiguous SPAWN setup pane'
            if not matches:
                return None
            prefs = self.ui('preferences', pane=matches[0])['properties']
            if prefs.get('page') == 'managed' and any(
                    row['id'] == 'managed-existing'
                    for section in prefs['sections'] for row in section['rows']):
                return matches[0]
            return None
        self.spawn_pane = self.lib.wait_for(pane, 'ordinary SPAWN managed setup page', self.ui.remaining(30))
        self.lib.wait_for(lambda: spawn_authority(self.runtime), 'SPAWN own first-use authority', self.ui.remaining(30))
        return self.spawn_pane

    def managed_advanced(self, pane):
        """Expose genuine Advanced fields only when fixture identity needs them."""
        prefs = self.ui('preferences', pane=pane)['properties']
        if not any(row['id'] == 'managed:id' for section in prefs['sections'] for row in section['rows']):
            self.ui.preference(pane, row='advanced')

    def prepared_record(self, pane):
        def ready():
            prefs = self.ui('preferences', pane=pane)['properties']
            return prefs if prefs.get('page') == 'managed' and any(
                row['id'] == 'managed-route-probe' and not row.get('disabled')
                for section in prefs['sections'] for row in section['rows']) else None
        return self.lib.wait_for(ready, 'actual resources prepared for native verification', self.ui.remaining(90))

    def check_native_navigation(self):
        ui = self.ui
        config = spawn_authority(self.runtime)['config']
        lifecycle = spawn_authority(self.runtime)['setup']
        owners = registry(self.runtime)['owners']
        orch_setup = registry(self.runtime)['setup']
        closed_target = self.spawn_pane
        ui('close', pane=closed_target)
        def navigate():
            self.open_defaults()
            ui.choose('Default settings — new orchestrations only', 'Agent setup')
        navigate()
        def managed_page():
            panes = [p['pane'] for p in ui('panes') if p.get('block') == 'spawn.spawner']
            if len(panes) != 1 or panes[0] == closed_target:
                return None
            return panes[0] if ui('preferences', pane=panes[0])['properties'].get('page') == 'managed' else None
        self.spawn_pane = self.lib.wait_for(managed_page, 'current grouped SPAWN cross-link', 30)
        self.capture('native-cross-link-new-spawn')
        ui.preference(self.spawn_pane, page='agents')
        navigate()
        assert self.lib.wait_for(managed_page, 'reuse SPAWN managed page', 30) == self.spawn_pane
        ui.preference(self.spawn_pane, row='managed-exercise')
        self.lib.wait_for(lambda: self.runtime.checked_state()['focused']['id'] == self.controller,
                          'SPAWN return to actual ORCH view', 30)
        assert registry(self.runtime)['owners'] == owners
        assert registry(self.runtime)['setup'] == orch_setup
        assert spawn_authority(self.runtime)['config'] == config
        assert spawn_authority(self.runtime)['setup'] == lifecycle
        self.capture('native-cross-link-return-orch')
        closed_source = ui('open', kind='orchplus.orchestrator')
        ui('action', pane=closed_source, action='plugin.orchplus.installation_defaults')
        self.lib.wait_for(lambda: 'Agent setup' in json.dumps(self.runtime.ctl('tree')), 'current navigation picker', 30)
        before = {p['pane'] for p in ui('panes')}
        ui('close', pane=closed_source)
        remained = 'Agent setup' in json.dumps(self.runtime.ctl('tree'))
        if remained:
            ui.choose('Default settings — new orchestrations only', 'Agent setup')
        assert {p['pane'] for p in ui('panes')} == before-{closed_source}
        assert spawn_authority(self.runtime)['config'] == config
        self.result['native_navigation'] = {'closed_target': closed_target, 'new_target': self.spawn_pane,
            'closed_source': closed_source, 'picker_remained': remained,
            'closed_source_case': 'delayed choice refused' if remained else 'native close dismissed picker',
            'orch_setup_unchanged': orch_setup, 'owners_unchanged': owners}
        self.result['checks'].append('grouped native cross-links reuse live targets, replace closed targets and refuse closed-source navigation without changing ownership/readiness')

    def create_record(self, record_id, provider, interrupt=False, *, coordinator=False, one_action=False):
        if coordinator:
            assert self.provider or self.provider_coordinator, 'Native OMP coordinator requires --provider-coordinator and approved --provider-agent-dir'
        dismiss_signin(self.runtime)
        initial_lifecycle = spawn_authority(self.runtime)['setup']['state']
        expected_lifecycle = 'adopted_existing' if initial_lifecycle == 'adopted_existing' else 'completed'
        interruptions = (('draft', 'resources', 'committed') if interrupt is True
                         else tuple(interrupt) if interrupt else ())
        assert all(boundary in ('draft', 'resources', 'committed') for boundary in interruptions), 'current setup has no human CLI-attestation boundary'
        if interrupt is True:
            self.result['setup_interruption_contract'] = {
                'boundaries': list(interruptions),
                'replacement': 'Removed human CLI attestation is not simulated. Resource preparation precedes native Verify and save; positive native cleanup commits automatically.'}
        def interrupt_at(boundary):
            if not interruptions or interruptions[0] != boundary:
                return False
            records = saved_records(self.runtime)
            lifecycle = spawn_authority(self.runtime)['setup']
            boot = trace(self.runtime, 'spawn')['boot']
            self.capture('spawn-interrupt-'+boundary)
            self.runtime.command('plugin', 'reload', 'spawn', '--json')
            self.lib.wait_for(lambda: trace(self.runtime, 'spawn').get('boot', 0) > boot,
                              'native setup interruption '+boundary, 30)
            self.open_spawn()
            assert saved_records(self.runtime) == records, 'interruption changed saved records at '+boundary
            assert spawn_authority(self.runtime)['setup'] == lifecycle, 'interruption rewrote setup lifecycle'
            if boundary != 'committed':
                assert not any(record['id'] == record_id for record in records), 'uncommitted setup became a record'
            self.result.setdefault('setup_interruptions', []).append({'boundary': boundary, 'state': lifecycle, 'record_ids': [row['id'] for row in records]})
            return True
        pane = self.spawn_pane
        self.ui.preference(pane, row='managed-existing', value='')
        self.managed_advanced(pane)
        values = {'id': record_id, 'provider': provider, 'account_label': record_id+' — deterministic fixture, no provider account',
                  'backend': 'local-terminal', 'executable': sys.executable,
                  'arguments': shlex.join([str(self.worker), str(self.control), record_id]),
                  'cwd': str(self.repository), 'root': str(self.runtime.root/'mailboxes'), 'user': ''}
        if self.provider or coordinator:
            other = record_id == 'c2-other-reviewer'
            model = 'anthropic/claude-opus-5-5' if other else 'openai-codex/gpt-6-astra'
            session_dir = self.runtime.root/'provider-sessions'/record_id
            session_dir.mkdir(parents=True, exist_ok=True)
            values.update(provider='OMP', account_label=record_id+' — approved '+model+' route, shared OS account',
                          backend='native-agent', executable=shutil.which('omp'),
                          arguments=shlex.join(['--model', model, '--thinking', 'low' if other else 'minimal',
                                                '--session-dir', str(session_dir), '--max-time', '300']))
            values['provider_family'] = 'anthropic' if other else 'openai'
        for key, value in values.items():
            self.ui.preference(pane, row='managed:'+key, value=value)
        self.capture('spawn-'+record_id+'-draft')
        if interrupt_at('draft'):
            return self.create_record(record_id, provider, interruptions[1:], coordinator=coordinator, one_action=one_action)
        if one_action:
            assert not interruptions, 'resource-interruption cases use the Advanced diagnostic path'
            self.prepare_and_save(pane, record_id)
        else:
            self.ui.preference(pane, row='managed-probe')
            observed = self.prepared_record(pane)
            self.result.setdefault('probes', {})[record_id] = observed
            self.capture('spawn-'+record_id+'-prepared')
            if interrupt_at('resources'):
                return self.create_record(record_id, provider, interruptions[1:], coordinator=coordinator)
            self.probe_native_route(pane, record_id)
        record = self.lib.wait_for(lambda: next((row for row in saved_records(self.runtime) if row['id'] == record_id), None),
                                   'native verified and automatically saved managed record '+record_id, self.ui.remaining(40))
        assert record['mailbox']['verified'] is True
        assert record['account_label'] == values['account_label'], 'native text input changed the account label bytes'
        assert spawn_authority(self.runtime)['setup']['state'] == expected_lifecycle, 'record creation changed the established setup lifecycle'
        assert spawn_authority(self.runtime)['setup']['readiness']['state'] == 'not_run'
        helper = Path(record['mailbox']['helper_path'])
        assert helper.is_relative_to(self.runtime.config/'plugin-data/spawn/helper-bundles')
        hashes = {}
        for asset in ASSETS:
            installed = helper.parent/asset
            hashes[asset] = hashlib.sha256(installed.read_bytes()).hexdigest()
        probes = list(Path(record['mailbox']['permitted_root']).glob('setup-*/provision.json'))
        assert probes, 'native preparation did not create an actual provision probe'
        self.result.setdefault('created_resources', {})[record_id] = {'record': record, 'bundle_sha256': hashes,
                                                                    'provisions': [str(path) for path in probes]}
        interrupt_at('committed')
        return record

    def prepare_and_save(self, pane, record_id):
        """One native click, then observe the actual diagnostic, cleanup and save."""
        before = spawn_authority(self.runtime)
        previous = self.ui.machine(pane, 'spawn.managed.route') or {}
        self.ui.preference(pane, row='managed-prepare')
        def completed():
            batch = self.ui.machine(pane, 'spawn.managed.prepare')
            if batch is None:
                return None
            assert len(batch['entries']) == 1 and batch['entries'][0]['record_id'] == record_id
            if batch['status'] == 'failed':
                raise AssertionError('one-action preparation failed: '+str(batch.get('error')))
            route = self.ui.machine(pane, 'spawn.managed.route')
            if route is None or route.get('nonce') == previous.get('nonce'):
                return None
            observations = self.result.setdefault('native_route_observations', {}).setdefault(record_id, [])
            if not observations or observations[-1]['route'] != route:
                observations.append({'at': time.time(), 'route': route})
            assert route['config_revision'] == batch['entries'][0]['revision']
            assert str(route['source_pane']) == str(pane)
            if route.get('status') == 'failed':
                raise AssertionError('one-action diagnostic failed: '+str(route.get('error')))
            if batch['status'] != 'completed':
                return None
            assert route.get('status') == 'passed' and route.get('observed') is True
            assert route.get('cleanup_pending') is False and not route.get('cleanup_only') and not route.get('error')
            authority = spawn_authority(self.runtime)
            assert authority['namespace'] == before['namespace']
            assert authority['config_revision'] == route['config_revision']+1
            assert authority.get('setup_probe') is None
            assert authority['setup']['readiness'] == before['setup']['readiness']
            record = next((row for row in saved_records(self.runtime) if row['id'] == record_id), None)
            assert record is not None and record.get('mailbox', {}).get('verified') is True
            return {'batch': batch, 'route': route, 'record': record}
        value = self.lib.wait_for(completed, 'one clicked preparation verified, cleaned, saved and refreshed', self.ui.remaining(180))
        self.result.setdefault('one_action_setup', {})[record_id] = value
        self.capture('spawn-'+record_id+'-one-action-saved')
        return value

    def probe_native_route(self, pane, record_id):
        """Await positive native cleanup and its durable automatic save, not a transient row."""
        before = spawn_authority(self.runtime)
        prior_route = self.ui.machine(pane, 'spawn.managed.route') or {}
        prefs = self.ui('preferences', pane=pane)['properties']
        fields = {row['id']: row.get('control', {}).get('value')
                  for section in prefs['sections'] for row in section['rows']}
        target_id = fields.get('managed:id') or fields.get('managed-existing') or record_id
        prior_record = next((row for row in before['config']['hosts'][before['host_key']]['agents']
                             if row['id'] == target_id), None)
        self.ui.preference(pane, row='managed-route-probe')
        def completed():
            route = self.ui.machine(pane, 'spawn.managed.route')
            observations = self.result.setdefault('native_route_observations', {}).setdefault(record_id, [])
            if route is not None and (not observations or observations[-1]['route'] != route):
                observations.append({'at': time.time(), 'route': route})
            if route is None or route.get('nonce') == prior_route.get('nonce'):
                return None
            assert route['config_revision'] == before['config_revision'], 'native diagnostic used a different configuration revision'
            assert str(route['source_pane']) == str(pane), 'native diagnostic belongs to another setup pane'
            if route.get('status') == 'failed':
                raise AssertionError('actual native route diagnostic failed: '+str(route.get('error') or route))
            if route.get('status') != 'passed':
                return None
            assert route.get('observed') is True and route.get('cleanup_pending') is False, 'native route lacks positive observation and cleanup'
            assert not route.get('cleanup_only') and not route.get('error'), 'native route did not qualify a fresh save'
            authority = spawn_authority(self.runtime)
            if authority['config_revision'] == before['config_revision']:
                return None
            assert authority['namespace'] == before['namespace'], 'SPAWN authority changed during verification'
            assert authority['config_revision'] == before['config_revision'] + 1, 'automatic save did not commit the exact prepared revision'
            assert authority.get('setup_probe') is None, 'native diagnostic cleanup obligation remains persisted'
            assert authority['setup']['config_revision'] == authority['config_revision']
            assert authority['setup']['state'] in ('completed', 'adopted_existing')
            assert authority['setup']['readiness'] == before['setup']['readiness'], 'route verification changed independent provider readiness'
            records = authority['config']['hosts'][authority['host_key']]['agents']
            record = next((row for row in records if row['id'] == target_id), None)
            assert record is not None and record.get('mailbox', {}).get('verified') is True, 'automatic save lacks the verified target record'
            for field, saved_field in (('provider', 'provider'), ('account_label', 'account_label'),
                                       ('backend', 'backend'), ('executable', 'fresh_executable'), ('cwd', 'cwd')):
                assert record[saved_field] == fields['managed:'+field], 'automatic save changed prepared '+field
            assert record['backend'] == route['backend'] and record['cwd'] == route['cwd']
            assert record['mailbox']['worker_identity'] == route['worker_identity']
            evidence_ref = record['mailbox'].get('evidence_ref')
            assert evidence_ref and (prior_record is None or evidence_ref != prior_record.get('mailbox', {}).get('evidence_ref')), 'automatic save reused an earlier preparation receipt'
            return {'route': route, 'record': record, 'config_revision': authority['config_revision'],
                    'setup': authority['setup'], 'preferences': self.ui('preferences', pane=pane)['properties']}
        observed = self.lib.wait_for(completed, 'actual consented native route diagnostic '+record_id, self.ui.remaining(120))
        self.result.setdefault('native_route_probes', {})[record_id] = observed
        self.capture('spawn-'+record_id+'-native-route')

    def add_catalog_padding(self):
        # Real ordinary editor records intentionally exceed one public catalog
        # frame. They are not managed/eligible and no workers are launched.
        pane = self.spawn_pane
        padding = []
        for index in range(3):
            prior = {record['id'] for record in saved_records(self.runtime)}
            self.ui.preference(pane, page='setup')
            self.ui.preference(pane, row='setup-add-local')
            record = self.lib.wait_for(lambda: next((row for row in saved_records(self.runtime) if row['id'] not in prior), None),
                                       'native pagination fixture record', 30)
            self.ui.preference(pane, page='agents')
            def label_row():
                prefs = self.ui('preferences', pane=pane)['properties']
                for section in prefs['sections']:
                    for row in section['rows']:
                        if row['id'].startswith('agent:'+record['id']+':account_label:'):
                            return row['id']
                return None
            row_id = self.lib.wait_for(label_row, 'ordinary saved-record label editor', 20)
            label = 'Pagination fixture '+str(index+1)+' '+'p'*1900
            self.ui.preference(pane, row=row_id, value=label)
            self.lib.wait_for(lambda: any(row['id'] == record['id'] and row['account_label'] == label for row in saved_records(self.runtime)),
                              'native pagination label save', 30)
            padding.append(record['id'])
        self.ui.preference(pane, page='managed')
        self.result['pagination_fixture_record_ids'] = padding

    def _initialize_legacy_orch(self, cold_navigation=False):
        self.controller = self.ui('open', kind='orchplus.orchestrator')
        if cold_navigation:
            config = spawn_authority(self.runtime)['config']
            closed = self.spawn_pane
            self.ui('close', pane=closed)
            self.ui.mouse_click(self.controller, 'SPAWN managed setup…')
            def opened():
                panes = [pane['pane'] for pane in self.ui('panes')
                         if pane.get('block') == 'spawn.spawner' and pane['pane'] != closed]
                return panes[0] if len(panes) == 1 else None
            self.spawn_pane = self.lib.wait_for(opened, 'cold ORCH native SPAWN cross-link', 30)
            self.lib.wait_for(lambda: 'Managed local setup' in json.dumps(self.ui('preferences', pane=self.spawn_pane)),
                              'cold-link owner Config bootstrap', 30)
            assert registry(self.runtime) is None, 'native navigation initialized ORCH authority'
            assert spawn_authority(self.runtime)['config'] == config
            self.capture('cold-orch-spawn-cross-link')
            self.result['checks'].append('actual cold ORCH cross-link opens owner SPAWN setup while ORCH authority remains absent')
        for label in ('Initialize first-use authority…', 'Confirm first use — no prior owners or lost store'):
            self.ui.click(self.controller, label)
        self.lib.wait_for(lambda: registry(self.runtime), 'genuine first-use ORCH authority', 30)
        self.assert_no_controller()

    def initialize_orch(self, cold_navigation=False):
        if getattr(self, 'legacy_source', False):
            return self._initialize_legacy_orch(cold_navigation)
        self.controller = self.ui('open', kind='orchplus.orchestrator')
        if cold_navigation:
            # First-use settings initialize only reusable configuration. They
            # must not allocate a logical session or controller.
            self.open_defaults()
            self.ui.choose('Default settings — new orchestrations only', 'Agent setup')
            self.open_spawn()
        return self.controller

    def create_orchestration(self, name, *, reuse=False, custom=False):
        """Create without launch; defaults then explicitly open the agent picker."""
        ui = self.ui
        workers_before = set((registry(self.runtime) or {}).get('dispatch', {}).get('workers', {}))
        deadline = time.monotonic()+90
        previous_deadline = getattr(ui, 'operation_deadline', None)
        ui.operation_deadline = min(deadline, previous_deadline) if previous_deadline else deadline
        try:
            if reuse:
                controls = surface_nodes(ui('surface', pane=self.controller).get('main'))
                if any(node.get('p', {}).get('text') == 'Back to work' or any(span.get('t') == 'Back to work' for span in node.get('p', {}).get('spans', [])) for node in controls):
                    ui.mouse_click(self.controller, 'Back to work')
                ui.mouse_click(self.controller, 'New orchestration')
            else:
                ui('action', action='plugin.orchplus.new_orchestration')
                def opened():
                    rows = [pane['pane'] for pane in ui('panes')
                            if pane.get('block') == 'orchplus.orchestrator']
                    assert len(rows) <= 1, 'creation opened multiple orchestration panels'
                    return rows[0] if rows else None
                self.controller = self.lib.wait_for(opened, 'new orchestration panel', ui.remaining(30))
            choice = ui.form_pane('New orchestration')
            ui.mouse_click(choice, 'Custom settings' if custom else 'Default settings')
            form = ui.form_pane('New orchestration')
            ui.edit_field(form, 'Orchestration name', name)
            ui.mouse_click(form, 'Create orchestration')
            def admitted():
                state = registry(self.runtime)
                if not state:
                    return None
                sessions = [session for session in state['sessions'].values() if session['name'] == name]
                assert len(sessions) <= 1, 'one creation produced duplicate logical sessions'
                scope = ui.machine(self.controller, 'orchplus.dispatch', 'dispatch-state')
                if len(sessions) == 1 and (scope or {}).get('session_control', {}).get('admitted'):
                    return sessions[0]
                return None
            session = self.lib.wait_for(admitted, 'automatic first-use connection', ui.remaining(60))
            assert set(registry(self.runtime)['dispatch']['workers']) == workers_before, 'creation started an agent before the explicit Start action'
            if not custom:
                ui.mouse_click(self.controller, 'Start orchestrator pane')
                project_choice = ui.form_pane('Choose a project')
                ui.mouse_click(project_choice, name)
            self.result.setdefault('conversation_sessions', []).append(session)
            return session
        finally:
            ui.operation_deadline = previous_deadline

    def assert_no_controller(self):
        authority = registry(self.runtime)
        assert authority is not None
        assert not authority.get('sessions'), 'setup fabricated a logical session before controller registration'
        assert not authority.get('owners'), 'setup fabricated an owner before controller registration'

    def _configure_legacy_orch(self, mode, wizard=True, previous=None):
        ui = self.ui
        ui('action', pane=self.controller, action='plugin.orchplus.orch_setup' if wizard else 'plugin.orchplus.installation_defaults')
        ui.choose('ORCH+ setup', 'Configure ORCH installation defaults')
        ui.choose('Choose review policy explicitly', MODES[mode][0])
        ui.enter('Repository checkout path', str(self.repository), str(self.repository) if previous else '')
        ui.enter('Existing target ref', 'refs/heads/main', 'refs/heads/main' if previous else '')
        ui.choose('Owner-declared landing queue', 'orch_queue')
        ui.choose('Select Builder', 'c2-builder')
        if self.provider and MODES[mode][1]:
            ui.enter('Declare provider family for c2-builder', 'openai')
        ui.choose('Select Release manager', 'c2-release')
        if MODES[mode][1]:
            ui.choose('Select Reviewer', MODES[mode][3])
            if self.provider:
                ui.enter('Declare provider family for '+MODES[mode][3],
                         'anthropic' if mode == 'cross_family_review' else 'openai')
        ui.choose('Select Coordinator (optional)', 'None — optional')
        ui.choose('Select Labeller (optional)', 'None — optional')
        if wizard:
            ui.choose('Required setup complete', 'Finish setup')
        def saved():
            value = registry(self.runtime)
            defaults = value and value.get('installation_defaults')
            if defaults and defaults['policy']['require_code_review'] == MODES[mode][1] and defaults['policy']['require_other_family'] == MODES[mode][2]:
                if not wizard or value['setup']['state'] in ('completed', 'adopted_existing'):
                    return defaults
            return None
        defaults = self.lib.wait_for(saved, 'native installation defaults '+mode, 40)
        self.result.setdefault('defaults', {})[mode] = defaults
        self.capture('orch-defaults-'+mode)
        return defaults

    def record_label(self, record_id, selected=False):
        record, = [row for row in saved_records(self.runtime) if row['id'] == record_id]
        providers = {'claude': 'Claude', 'anthropic': 'Claude', 'codex': 'Codex',
                     'openai': 'Codex', 'omp': 'OMP', 'kimi': 'Kimi', 'muse': 'Muse',
                     'antigravity': 'Antigravity', 'grok': 'Grok'}
        label = providers.get(record['provider'].lower(), record['provider'])+' · '+(record.get('account_label') or 'account unknown')
        return label+(' · selected' if selected else '')

    def open_defaults(self, wizard=False):
        """Open the retained in-pane defaults editor, never a floating wizard."""
        ui = self.ui
        state = registry(self.runtime)
        cold = state is None
        if cold:
            ui.mouse_click(self.controller, 'Define Default Settings')
        else:
            ui('action', pane=self.controller,
               action='plugin.orchplus.orch_setup' if wizard else 'plugin.orchplus.installation_defaults')
        defined = state and state['installation_defaults'].get('defined') is True
        form = ui.form_pane('Edit Default Settings' if defined else 'Define Default Settings')
        if cold:
            self.assert_no_controller()
        return form


    def configure_orch(self, mode, wizard=True, previous=None, *, preferred_worker='c2-builder', release_manager='c2-release', report_polling=None):
        """Edit reusable defaults using native groups, fields and save controls."""
        if getattr(self, 'legacy_source', False):
            return self._configure_legacy_orch(mode, wizard, previous)
        if mode not in MODES:
            raise ValueError('unknown policy mode '+mode)
        ui = self.ui
        deadline = time.monotonic()+180
        outer = getattr(ui, 'operation_deadline', None)
        ui.operation_deadline = min(outer, deadline) if outer else deadline
        try:
            form = self.open_defaults(wizard)
            before = registry(self.runtime)['installation_defaults']
            policy = before['policy']
            ui.click_match(form, 'Agents and Routing')
            ui.select_field(form, 'Preferred Worker', preferred_worker)
            ui.click_match(form, 'Agents and Routing')
            ui.click_match(form, 'Review and Completion')
            ui.switch_field(form, 'Require review', MODES[mode][1])
            desired = list(policy['reviewer_records'])
            if MODES[mode][1]:
                ui.switch_field(form, 'Require a different declared family', MODES[mode][2])
                desired = [MODES[mode][3]]
                for record in [row for row in policy['reviewer_records'] if row not in desired]:
                    ui.switch_field(form, self.record_label(record), False)
                for record in [row for row in desired if row not in policy['reviewer_records']]:
                    ui.switch_field(form, self.record_label(record), True)
            ui.select_field(form, 'Release manager', 'record:'+release_manager)
            if report_polling is not None:
                ui.click_match(form, 'ADVANCED')
                ui.edit_field(form, 'Report polling', report_polling)
            prior_result = (ui.machine(self.controller, 'orchplus.setup', 'setup-index') or {}).get('setup_result')
            ui.mouse_click(form, 'SAVE AS DEFAULT ORCHESTRATION SETTINGS')
            def saved():
                state = registry(self.runtime)
                defaults = state['installation_defaults']
                response = (ui.machine(self.controller, 'orchplus.setup', 'setup-index') or {}).get('setup_result')
                if response == prior_result or not response or not response.get('ok'):
                    return None
                p = defaults['policy']
                if (p['preferred_worker_record'] == preferred_worker
                        and p['merge_actor_mode'] == 'selected_record'
                        and p['release_manager_record'] == release_manager
                        and (p['reviewer_records'] or []) == desired
                        and p['require_code_review'] == MODES[mode][1]
                        and p['require_other_family'] == MODES[mode][2]):
                    return defaults
                return None
            defaults = self.lib.wait_for(saved, 'native default settings committed', ui.remaining(40))
            self.result.setdefault('defaults', {})[mode] = defaults
            self.capture('orch-defaults-'+mode)
            return defaults
        finally:
            ui.operation_deadline = outer


    def qualify_native_pair(self):
        def spawn_store():
            return (read_json(self.runtime.config/'plugin-data/spawn/kv.json') or {}).get('dispatch-v1')

        def paired():
            authority, peer = registry(self.runtime), spawn_store()
            compatibility = authority.get('compatibility') if authority else None
            return bool(peer and compatibility and compatibility.get('kind') == 'current'
                        and compatibility['authority_namespace'] == authority['authority_namespace']
                        and compatibility['spawn_namespace'] == peer['namespace']
                        and peer.get('authority_namespace') == authority['authority_namespace']
                        and not peer.get('migration'))

        if not paired():
            self.ui.click(self.controller, 'Update / reconnect')
            self.lib.wait_for(paired, 'one-button paired native update', self.ui.remaining(180))
            self.result['native_pairing'] = {
                'orch': registry(self.runtime)['compatibility'],
                'spawn_namespace': spawn_store()['namespace'],
                'route': 'one visible Update / reconnect action; internal stages observed, never manually replayed'}
        return spawn_store()

    def _claim_legacy(self, *, legacy=True):
        assert legacy and registry(self.runtime)['version'] == 3, 'baseline-only registration requires actual prior-version authority'
        for label in ('Register a distinct logical session…', 'Confirm distinct session registration', 'Claim controller in this pane'):
            self.ui.click(self.controller, label)
        def controller_scope():
            state = self.ui.machine(self.controller, 'orchplus.dispatch', 'dispatch-state')
            if not state or state.get('controller_phase') != 'active':
                return None
            return {key: state.get(key) for key in
                    ('source_nonce', 'host_pane_id', 'orch_session_id', 'owner_id', 'owner_generation')}
        scope = self.lib.wait_for(controller_scope, 'native claimed controller scope', 30)
        last_read = 0.0
        def catalog_ready():
            nonlocal last_read
            assert controller_scope() == scope, 'controller scope changed during catalog navigation'
            state = registry(self.runtime)
            busy = [action for action in state.get('dispatch', {}).get('actions', {}).values()
                    if action.get('request', {}).get('op') == 'catalog' and action.get('phase') != 'complete']
            intent = self.ui.machine(self.controller, 'orchplus.intent', 'operator-intent')
            if busy or intent is not None:
                return None
            catalog = self.ui.machine(self.controller, 'orchplus.catalog', 'catalog-index')
            if catalog and any(record['id'] == 'c2-builder' for record in catalog.get('records', [])):
                return catalog
            if time.monotonic() - last_read >= 2:
                last_read = time.monotonic()
                # Re-read navigation only; assignment and authority acquisition
                # are never repeated on an unconfirmed control submission.
                self.ui.click(self.controller, 'Load configured SPAWN catalog')
            return None
        self.lib.wait_for(catalog_ready, 'native configured builder catalog projection', 30)
        peer = read_json(self.runtime.config/'plugin-data/spawn/kv.json')['dispatch-v1']
        assert peer['version'] == 1, 'legacy qualification did not create the prior managed store'

    def claim(self, *, legacy=False):
        """Create one ordinary orchestration after setup, then observe admission."""
        if legacy or getattr(self, 'legacy_source', False):
            return self._claim_legacy(legacy=True)
        ui = self.ui
        ui('focus', pane=self.controller)
        scope = ui.machine(self.controller, 'orchplus.dispatch', 'dispatch-state')
        if not scope or not scope.get('orch_session_id'):
            count = len((registry(self.runtime) or {}).get('sessions', {}))
            self.create_orchestration('Native qualification '+str(count+1), reuse=True)
            ui.mouse_click(ui.agent_picker('Choose your orchestrator'), 'Close')
        def admitted():
            observed = ui.machine(self.controller, 'orchplus.dispatch', 'dispatch-state')
            if not observed or observed.get('controller_phase') != 'active':
                return None
            state = registry(self.runtime)
            session = state['sessions'][observed['orch_session_id']]
            peer = (read_json(self.runtime.config/'plugin-data/spawn/kv.json') or {}).get('dispatch-v1', {})
            counterpart = peer.get('sessions', {}).get(observed['orch_session_id'])
            return observed if (session.get('admitted') and counterpart
                and counterpart['admission_seq'] == session['admission_seq']
                and session['spawn_namespace'] == peer['namespace']) else None
        return self.lib.wait_for(admitted, 'automatically admitted native controller', ui.remaining(40))

    def current_project(self):
        self.ui('focus', pane=self.controller)
        scope = self.ui.machine(self.controller, 'orchplus.dispatch', 'dispatch-state')
        assert scope and scope.get('orch_session_id'), 'project requires a current controller'
        projects = [row for row in registry(self.runtime)['dispatch']['projects'].values()
                    if row['logical_session_id'] == scope['orch_session_id'] and not row.get('finished')]
        assert len(projects) == 1, 'select a unique project before using the qualification helper'
        return projects[0]

    def configure_repository(self, checkout, target='refs/heads/main', route='orch_queue'):
        """Save this project's repository through its native host-verified form."""
        assert route in ('orch_queue', 'repository_queue')
        project = self.current_project()
        ui = self.ui
        ui.command(self.controller, 'project_menu')
        ui.choose(project['name'], 'Settings')
        ui.choose('Project settings · '+project['name'], 'Code and merging')
        form = ui.form_pane('Code and merging · '+project['name'])
        # The chooser may already know a folder, but selecting another folder
        # remains a real, explicit project edit rather than a fixture-state write.
        def ready():
            surface = ui('surface', pane=form)
            return surface if any(node.get('p', {}).get('actions', {}).get('click') in
                                  ('form-action=change_folder', 'form-action=edit', 'form-action=save')
                                  for node in surface_nodes(surface.get('main'))) else None
        surface = self.lib.wait_for(ready, 'repository discovery finished', ui.remaining(40))
        change = next(node['p'] for node in surface_nodes(surface.get('main'))
                      if node.get('p', {}).get('actions', {}).get('click') == 'form-action=change_folder')
        change_label = change.get('text', ''.join(span if isinstance(span, str) else span.get('t', '')
                                                for span in change.get('spans', [])))
        ui.mouse_click(form, change_label)
        ui.edit_field(form, 'Project folder', str(checkout))
        ui.mouse_click(form, 'Use this folder')
        self.lib.wait_for(lambda: any(node.get('k') == 'select' and
                          node.get('p', {}).get('key') == 'field:target_ref'
                          for node in surface_nodes(ui('surface', pane=form).get('main'))),
                          'host repository branch choices', ui.remaining(40))
        if not any(node.get('p', {}).get('actions', {}).get('click') == 'form-action=save'
                   for node in surface_nodes(ui('surface', pane=form).get('main'))):
            ui.mouse_click(form, 'Edit')
        if target is not None:
            ui.select_field(form, 'Merge changes into', target)
        if route != 'orch_queue':
            ui.click_match(form, 'Advanced')
            ui.select_field(form, 'Who handles merges?', route)
        ui.mouse_click(form, 'Verify and save')
        def associated():
            current = registry(self.runtime)['dispatch']['projects'][project['orch_project_id']]
            repository = current.get('repository')
            return repository if repository and repository['queue_route'] == route and (target is None or repository['target_ref'] == target) and current['revision'] > project['revision'] else None
        return self.lib.wait_for(associated, 'host-verified project repository association', ui.remaining(40))


def prerequisites():
    required = ('xvfb-run', 'git', 'sh', 'jq', 'awk', 'iconv', 'base64', 'sha256sum')
    missing = [binary for binary in required if not shutil.which(binary)]
    if sys.platform != 'linux' or missing:
        return {'status': 'unavailable', 'platform': sys.platform, 'missing': missing,
                'reason': 'C2 ordinary desktop adapter requires Linux; no mock platform qualification'}
    return None


def additional_window(product):
    runtime, lib = product.runtime, product.lib
    first_key = product.ui('context')['window']
    product.ui.window_key = first_key
    runtime.ctl('palette', 'New window')
    def offered():
        tree = runtime.ctl('tree')
        choices = [node for node in native_nodes(tree.get('tree', [])) if node.get('role') == 'option' and any(
            ' '.join(child.get('text', '') for child in native_nodes(label) if child.get('text')).casefold() == 'new window'
            for label in native_nodes(node) if label.get('class') == 'ck-label')]
        return choices[0] if len(choices) == 1 else None
    node = lib.wait_for(offered, 'native New window palette option', 30)
    x, y, width, height = node['rect']
    runtime.ctl('click', str(x+width/2), str(y+height/2))
    product.ui.record_input({'op': 'native_picker', 'title': 'Native command palette', 'label': 'New window', 'control': node})

    class Window:
        def __getattr__(self, name):
            return getattr(runtime, name)

        def ctl(self, *parts):
            if parts[0] in ('state', 'plugins'):
                raise AssertionError('native root-app command is not retargeted to the second window; use its rendered controls')
            runtime.ctl('target', 'window')
            try:
                return runtime.ctl(*parts)
            finally:
                runtime.ctl('target', 'main')

    window = Window()
    wake = lambda: window.ctl('tree')
    lib.WAKERS.append(wake)
    product.extra_wakers = [*getattr(product, 'extra_wakers', []), wake]
    def announced():
        for path in product.ui.data.glob('ready-window-*.json'):
            value = read_json(path)
            if value and value['window_key'] != first_key:
                return value
        return None
    observed = lib.wait_for(announced, 'second native UI driver registration', 40)
    second = NativeUI(window, lib, observed['window_key'])
    dismiss_signin(second.runtime)
    product.result['second_window'] = {'control_socket': str(runtime.control), 'native_target': 'window', 'native': observed,
                                       'control_limit': 'state and plugins run remain root-app scoped; second-window actions use its rendered owner controls'}
    return second




def product_setup(base, root, evidence, processes, lib, args):
    unavailable = prerequisites()
    if unavailable:
        return unavailable
    product = Product(base, root, evidence, processes, lib, 'setup-product', args)
    result, runtime = product.result, product.runtime
    try:
        product.start()
        product.open_spawn()
        assert registry(runtime) is None, 'standalone SPAWN setup required an ORCH controller'
        product.capture('cold-standalone-spawn')
        assert spawn_authority(runtime)['setup']['state'] == 'not_started'
        product.managed_advanced(product.spawn_pane)
        for field, value in {'provider': 'Codex', 'backend': 'local-terminal',
                             'executable': sys.executable,
                             'arguments': shlex.join([str(product.worker), str(product.control), 'dismissed-draft']),
                             'cwd': str(product.repository)}.items():
            product.ui.preference(product.spawn_pane, row='managed:'+field, value=value)
        product.ui.preference(product.spawn_pane, row='managed-probe')
        product.prepared_record(product.spawn_pane)
        assert spawn_authority(runtime)['setup']['state'] == 'in_progress'
        product.ui.preference(product.spawn_pane, row='managed-dismiss')
        lib.wait_for(lambda: spawn_authority(runtime)['setup']['state'] == 'dismissed', 'persisted native setup dismissal', 30)
        assert not saved_records(runtime) and spawn_authority(runtime)['setup']['readiness']['state'] == 'not_run'
        result['checks'].append('Prepare agent begins persisted setup; Advanced dismissal preserves resources without creating records or claiming readiness')
        product.add_catalog_padding()
        product.create_record(*RECORDS[0], interrupt=True)
        for record in RECORDS[1:]:
            product.create_record(*record)
        result['checks'].append('cold standalone Prepare agent and Verify and save create exact stable helper bundles/resources before any ORCH authority/controller')
        product.initialize_orch(cold_navigation=True)
        product.check_native_navigation()
        before_draft = registry(runtime)['installation_defaults']
        product.open_defaults(wizard=True)
        product.ui.choose('Default settings — new orchestrations only', 'Work')
        product.ui.choose('Work', 'Start added work automatically: Off')
        runtime.ctl('key', 'Escape')
        boot = trace(runtime, 'orchplus')['boot']
        runtime.command('plugin', 'reload', 'orchplus', '--json')
        lib.wait_for(lambda: trace(runtime, 'orchplus').get('boot', 0) > boot, 'interrupted grouped settings reload', 30)
        assert registry(runtime)['installation_defaults'] == before_draft, 'unsaved settings were committed by reload'
        product.configure_orch('review_disabled')
        assert registry(runtime)['setup']['readiness']['state'] == 'not_run'
        assert not registry(runtime)['dispatch']['workers']
        product.assert_no_controller()
        result['checks'].append('unsaved grouped draft survives no implicit commit; explicit saved setup creates no workers or provider readiness')
        previous_defaults = dict(registry(runtime)['installation_defaults'])
        previous_defaults.pop('revision')
        product.configure_orch('review_disabled', previous=True)
        identical_defaults = dict(registry(runtime)['installation_defaults'])
        identical_defaults.pop('revision')
        assert identical_defaults == previous_defaults and registry(runtime)['setup']['state'] == 'completed'
        catalog_requests = [json.loads(event['data']['value']) for event in trace(runtime, 'spawn')['events']
                            if event['kind'] == 'bridge_event' and event['data']['act'] == 'catalog']
        paged = [request for request in catalog_requests if request.get('setup_origin') and request.get('cursor')]
        builder_index = next(index for index, record in enumerate(saved_records(runtime), 1) if record['id'] == 'c2-builder')
        assert paged and min(request['cursor']['index'] for request in paged) <= builder_index, 'setup roles were not fetched beyond the first actual catalog page'
        result['setup_catalog_pagination'] = paged
        result['checks'].append('interrupted unsaved settings do not commit; identical defaults complete; actual paginated catalog resolves saved roles')

        # Existing-record adoption uses the ordinary managed editor and its
        # fresh probe; it does not fabricate a pre-migration store.
        pane = product.spawn_pane
        before = saved_records(runtime)
        lifecycle_before_adoption = spawn_authority(runtime)['setup']['state']
        product.ui.preference(pane, row='managed-existing', value='c2-builder')
        product.ui.preference(pane, row='managed:account_label', value='Manually edited deterministic fixture')
        product.ui.preference(pane, row='managed-probe')
        product.prepared_record(pane)
        product.probe_native_route(pane, 'c2-builder-adoption')
        lib.wait_for(lambda: next((record for record in saved_records(runtime)
                                  if record['id'] == 'c2-builder' and record['account_label'] == 'Manually edited deterministic fixture'), None),
                     'persisted native adopted record edit', 30)
        assert spawn_authority(runtime)['setup']['state'] == lifecycle_before_adoption, 'editing an existing record reopened completed setup'
        after = saved_records(runtime)
        assert len(after) == len(before) and {row['id'] for row in after} == {row['id'] for row in before}
        assert next(row for row in after if row['id'] == 'c2-builder')['account_label'] == 'Manually edited deterministic fixture'
        assert spawn_authority(runtime)['setup']['readiness']['state'] == 'not_run'
        result['checks'].append('manual native edit and fresh probe/adoption preserve stable IDs and independent readiness')

        # A real second window opens an ordinary defaults prompt with the old
        # revision. Another window commits; the stale prompt must not overwrite.
        second = additional_window(product)
        second_pane = second('open', kind='orchplus.orchestrator')
        second('action', pane=second_pane, action='plugin.orchplus.installation_defaults')
        second.choose('Default settings — new orchestrations only', 'Review and completion')
        second.choose('Review and completion', 'Require review: Off')
        second.choose('Review and completion', 'Back')
        old_revision = registry(runtime)['installation_defaults']['revision']
        product.configure_orch('helper_checks', wizard=False, previous=True)
        winner = registry(runtime)['installation_defaults']
        assert winner['revision'] > old_revision
        # Submit the retained old grouped draft exactly once after the other
        # window wins; the captured configuration revision must be refused.
        second.choose('Default settings — new orchestrations only', 'Save as my default settings')
        def stale_result():
            data = second.machine(second_pane, 'orchplus.setup') or {}
            response = data.get('setup_result') or {}
            return response if response.get('ok') is False else None
        refused = lib.wait_for(stale_result, 'two-window stale defaults revision refusal', 40)
        assert registry(runtime)['installation_defaults'] == winner
        result['two_window_refusal'] = refused
        result['second_window']['inputs'] = second.inputs
        result['checks'].append('two real desktop windows: stale ordinary defaults prompt cannot overwrite the winning revision')

        # Creation, not manual registration, is the inheritance boundary.
        first_scope = product.claim()
        first_id = first_scope['orch_session_id']
        first_policy = registry(runtime)['dispatch']['policies'][first_id]
        assert first_policy['require_code_review'] and not first_policy['require_other_family']
        product.configure_orch('review_disabled', wizard=False, previous=True)
        assert registry(runtime)['dispatch']['policies'][first_id] == first_policy
        original_ui, original_controller = product.ui, product.controller
        product.ui = second
        try:
            product.create_orchestration('Second-window inherited settings')
            second_pane = product.controller
            second.click(second.agent_picker('Choose your orchestrator'), 'Cancel')
            second_scope = product.claim()
        finally:
            product.ui, product.controller = original_ui, original_controller
        new_policy = registry(runtime)['dispatch']['policies'][second_scope['orch_session_id']]
        assert not new_policy['require_code_review'] and not new_policy['require_other_family']
        result['checks'].append('saved defaults preserve existing session policy; ordinary new orchestration in another window inherits current defaults')

        # Decline actual readiness using the native consent surface. No worker,
        # fake report or readiness pass is created by refusing the exercise.
        second('action', pane=second_pane, action='plugin.orchplus.orch_readiness')
        second.choose('Optional readiness', 'Not now — keep completed setup')
        assert registry(runtime)['setup']['state'] == 'completed'
        assert registry(runtime)['setup']['readiness']['state'] != 'passed'
        result['checks'].append('optional actual readiness refusal leaves required setup completed')
        saved = {plugin: read_json(runtime.config/'plugin-data'/plugin/'kv.json')
                 for plugin in ('spawn', 'orchplus')}
        for plugin in ('spawn', 'orchplus'):
            old_boot = trace(runtime, plugin)['boot']
            runtime.command('plugin', 'reload', plugin, '--json')
            lib.wait_for(lambda: trace(runtime, plugin).get('boot', 0) > old_boot, 'native '+plugin+' reload', 30)
        assert spawn_authority(runtime)['config'] == saved['spawn']['authority']['config']
        assert registry(runtime)['installation_defaults'] == saved['orchplus']['authority_state']['installation_defaults']
        assert registry(runtime)['setup']['state'] == 'completed'
        product.capture('setup-after-native-reload')
        result['checks'].append('native host/window reload preserves one saved configuration/defaults/lifecycle')
        result['corrupt_store'] = corrupt_store_refusal(product)
        result['unverified_matrix'] = [
            'Lost-store recovery and immutable outstanding-grant migration require dedicated qualification',
            'Successive changed-helper package digest rollover remains separate qualification; native setup interruptions are exercised at draft, prepared-resource and committed-record boundaries',
            'Provider-backed readiness/task/check/landing and actual macOS/Windows/cross-user routes remain separate qualification',
        ]
        result['status_scope'] = 'listed ordinary native setup observations only; unverified_matrix is not accepted as covered'
        product.hold()
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_traceback'] = traceback.format_exc()
        result['failure_diagnostics'] = window_diagnostics(runtime, 'setup-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        product.close()
    if args.legacy_archive:
        result['legacy_update_adoption'] = product_legacy_setup(base, root, evidence, processes, lib, args)
        if result['legacy_update_adoption']['status'] != 'passed':
            result['status'] = result['legacy_update_adoption']['status']
    else:
        result['legacy_update_adoption'] = {'status': 'unavailable', 'reason': '--legacy-archive must identify actual prior-version source for native create/update/adoption'}
        if result['status'] == 'passed':
            result['status'] = 'unavailable'
    return result


def worker_observations(product, handle):
    error = read_json(product.control/handle/'error.json')
    assert not error, error
    return read_json(product.control/handle/'observations.json') or {'events': []}


def provider_coordinator_command(product, worker, operation, payload=None):
    """Ask the real provider to use its helper; observe, never manufacture, proof."""
    deadline = time.monotonic()+product.ui.remaining(180)
    identity = provider_coordinator_identity(product, worker)
    expected = json.loads(json.dumps(payload)) if payload is not None else None
    before = identity['provider_identity']['assistant_responses']
    record = identity['saved_record']
    box = Path(record['mailbox']['permitted_root'])/worker['mailbox_handle']
    if operation == 'propose-task':
        assert isinstance(expected, dict) and expected.get('proposal_id') and expected.get('kind')
        assert not set(expected).intersection(('owner_id', 'owner_generation', 'activation_token')), 'activation comes from the provider-consumed reply only'
        assert worker.get('activation', {}).get('acknowledged')
        request = (
            'Bounded disposable hybrid qualification: deterministic terminal task workers, '
            'not provider-worker qualification. Submit exactly ONE COORDINATOR_PROPOSAL using '
            'your startup producer helper report mode. Preserve every JSON field and array '
            'exactly; add ONLY owner_id, owner_generation, activation_token from your own '
            'consumed and acknowledged coordinator_activation. Do not invent or edit activation, '
            'producer journals, receipts, authority, capabilities or task results. Do not launch '
            'workers or implement this assignment yourself. Use the supported helper and wait '
            'for its report ACK, settle receipts, then return idle. On later native wake, '
            'consume the actual owner_decision, claim and resolve that exact message, settle '
            'its ACK receipts and return idle; approval does not authorize you to execute the '
            'child task yourself. Do not independently propose other work or answer permission '
            'prompts. If uncertain, report the blocker, never allocate a replacement proposal. '
            'Requested payload:\n'+json.dumps(expected, ensure_ascii=False))
    else:
        assert operation in ('receipts', 'drain'), 'unsupported native coordinator command '+operation
        request = ('Use your startup producer helper receipts mode to settle actual ACKs now. '
                   'Do not write any producer files directly, invent receipts, propose work, '
                   'or answer permission prompts. Return idle after the bounded operation.')
        if operation == 'drain':
            request += (
                ' Also consume pending owner_decision controls through your helper, claim and '
                'resolve each exact message, and settle its ACK receipts. Wait at most 30 seconds '
                'for already-issued controls using bounded helper waits, then return idle. '
                'Do not execute child work, change documents, resolve unrelated controls, or '
                'treat a reply ACK as permission. On uncertainty stop and report the blocker.')
    provider_coordinator_prompt(product, worker, request, deadline=deadline)

    def completed():
        product.runtime.assert_running()
        state = registry(product.runtime)
        current = state['dispatch']['workers'][worker['worker_id']]
        assert current['worker_generation'] == worker['worker_generation']
        if operation == 'propose-task':
            matches = [gate for gate in state['dispatch']['gates'].values()
                       if gate.get('kind') == 'coordinator_proposal'
                       and gate.get('worker_id') == worker['worker_id']
                       and json.loads(gate['proposal'])['payload'].get('proposal_id') == expected['proposal_id']]
            assert len(matches) <= 1, 'provider duplicated immutable proposal'
            if not matches:
                return None
            gate = matches[0]
            proposal = json.loads(gate['proposal'])
            exact = dict(expected, owner_id=worker['coordinator_owner_id'],
                         owner_generation=worker['coordinator_generation'],
                         activation_token=worker['activation']['activation_token'])
            assert proposal['kind'] == 'COORDINATOR_PROPOSAL' and proposal['payload'] == exact, 'provider changed exact requested proposal'
            for key in ('logical_session_id', 'worker_id', 'worker_generation', 'work_id', 'launch_request_id'):
                assert proposal[key] == worker[key], 'proposal origin changed: '+key
            assert gate['worker_generation'] == worker['worker_generation']
            assert proposal['seq'] <= current['accepted_seq'], 'proposal report not accepted'
            product.result.setdefault('hybrid_coordinator_proposals', []).append({
                'requested': expected, 'accepted_report': proposal, 'gate_id': gate['id'],
                'qualification_scope': 'provider-produced exact test intent, not autonomous provider task reasoning'})
            return gate
        agents = [row for row in product.ui('agents')
                  if str(row['pane']) == str(current['pane_binding']['pane_id'])]
        if not agents or agents[0]['state'] != 'idle':
            return None
        proof = provider_coordinator_identity(product, current)
        if proof['provider_identity']['assistant_responses'] <= before:
            return None
        journal = read_json(box/'producer/journal.json')
        if not journal or journal['receipt_seq'] < current['accepted_seq']:
            return None
        assert journal['binding'] == {key: worker[key] for key in (
            'logical_session_id', 'worker_id', 'worker_generation', 'work_id', 'launch_request_id', 'enrolment_token')}
        if operation == 'drain':
            if (journal.get('consumed') or journal['consumed_reply_floor'] != current['reply_seq']
                    or current.get('replies') or current.get('wakes') or current.get('receipts')
                    or current.get('accept_pending') or current.get('compaction_pending')
                    or current['compacted_floor'] != current['accepted_seq']
                    or current['reply_floor'] != current['reply_seq']
                    or any(gate['worker_id'] == worker['worker_id'] and gate['phase'] == 'answered'
                           for gate in state['dispatch']['gates'].values())
                    or any(action.get('worker_id') == worker['worker_id']
                           for action in state['dispatch']['actions'].values())):
                return None
        product.result.setdefault('hybrid_coordinator_receipts', []).append(journal)
        return journal
    return product.lib.wait_for(completed, 'genuine Native OMP '+operation+' evidence',
                                max(0, deadline-time.monotonic()), .1)


def worker_command(product, handle, operation, payload=None):
    workers = [row for row in registry(product.runtime)['dispatch']['workers'].values()
               if row.get('mailbox_handle') == handle]
    assert len(workers) == 1, 'command must name exactly one actual worker'
    selected, = [row for row in saved_records(product.runtime) if row['id'] == workers[0]['record_id']]
    if selected['backend'] == 'native-agent':
        return provider_coordinator_command(product, workers[0], operation, payload)
    directory = product.control/handle
    serial = time.time_ns()//1000
    pending = directory/'command.pending'
    pending.write_text(json.dumps({'id': serial, 'op': operation, **({'payload': payload} if payload is not None else {})}))
    os.replace(pending, directory/'command.json')
    def completed():
        product.runtime.assert_running()
        worker_observations(product, handle)
        value = read_json(directory/'command-result.json')
        return value if value and value['id'] == serial else None
    return product.lib.wait_for(completed, 'actual deterministic worker '+operation, product.ui.remaining(600), .1)


def landing_for(product, worker_id, snapshot=None):
    state = registry(product.runtime) if snapshot is None else snapshot
    items = ((state or {}).get('dispatch', {}).get('landing') or {}).get('items', {})
    candidates = [item for item in items.values() if item['worker_id'] == worker_id]
    # Latest native request; do not manufacture a landing record when none exists.
    return max(candidates, key=lambda item: int(item['id'].rsplit('-', 1)[1]), default=None)


def approve_landing(product, worker, expected_item=None):
    ui, pane = product.ui, product.controller
    scope = ui.machine(pane, 'orchplus.dispatch', 'dispatch-state')
    assert scope and scope.get('controller_phase') == 'active', 'landing control requires current controller'
    original_origin = (scope.get('command_cursor') or {}).get('origin')
    def pending():
        state = registry(product.runtime)
        item = landing_for(product, worker['worker_id'], state)
        if not item or not item.get('gate_id'):
            return None
        if expected_item is not None:
            assert item['id'] == expected_item['id'] and item['gate_id'] == expected_item['gate_id'] and item['request'] == expected_item['request'], 'owner decision changed after scoped approval; refusing a different request'
        gate = state['dispatch'].get('gates', {}).get(item['gate_id'])
        return (item, gate) if gate and gate['phase'] == 'pending' else None
    pinned_item, gate = product.lib.wait_for(pending, 'actual landing owner decision', 40)
    visible = ui.machine(pane, 'orchplus.gate', 'workflow-gate-'+gate['id'])
    content = ui.machine(pane, 'orchplus.gate-content', 'workflow-gate-content-'+gate['id'])
    assert visible and content and content.get('question') == gate['question'] and content.get('options') == gate['options']
    product.result.setdefault('gate_picker_observations', []).append({
        'monotonic_ns': time.monotonic_ns(), 'gate': gate, 'surface': content,
        'scope': scope, 'landing': pinned_item})
    answer_owner_gate(product, gate, answer='Approve only this exact disposable qualification landing.')
    def committed_answer():
        state = registry(product.runtime)
        item = landing_for(product, worker['worker_id'], state)
        assert item and item['id'] == pinned_item['id'] and item['request'] == pinned_item['request'], 'landing request changed while awaiting the submitted decision'
        current = state['dispatch']['gates'].get(gate['id'])
        assert current and all(current.get(key) == gate.get(key) for key in
                               ('id', 'revision', 'worker_id', 'worker_generation', 'question', 'options')), 'submitted decision no longer names the original gate'
        answer = current.get('answer')
        if answer is None:
            assert current['phase'] == 'pending', 'submitted owner decision was not accepted'
            return None
        assert answer['choice_id'] == 'approve' and answer['source']['kind'] == 'owner'
        assert all(answer['source'].get(key) == value for key, value in (original_origin or {}).items()), 'decision came from another controller origin'
        return current
    return product.lib.wait_for(committed_answer, 'exact submitted owner decision committed', 40)


def policy_cell(base, root, evidence, processes, lib, args, mode, case):
    unavailable = provider_prerequisite(args, coordinator=True)
    if unavailable:
        return unavailable
    product = Product(base, root, evidence, processes, lib, 'policy-'+mode+'-'+case, args)
    result, runtime = product.result, product.runtime
    result.update(mode=mode, declared_checks=case)
    def worker_health():
        for path in product.control.glob('*/error.json'):
            error = read_json(path)
            if error:
                result.setdefault('worker_failures', {})[str(path)] = error
                raise AssertionError('actual deterministic worker failed; see '+str(path))
    try:
        product.start()
        lib.WAKERS.append(worker_health)
        product.open_spawn()
        required = {'c2-builder', 'c2-release', MODES[mode][3]}
        for record in RECORDS:
            if record[0] in required:
                product.create_record(*record)
        product.initialize_orch()
        product.configure_orch(mode)
        product.claim()
        ui, pane = product.ui, product.controller
        ensure_fixture_coordinator(product, deadline=time.monotonic()+240)
        product.configure_repository(product.repository)
        check = '' if case == 'empty' else 'fixture: '+shlex.join([
            sys.executable, '-c', "from pathlib import Path; raise SystemExit(0 if Path('fixture.txt').read_text().splitlines()[0]=='good' else 7)"])
        owner_assignment(product, 'c2-builder', (
            ('Explicit assignment for c2-builder', 'C2_CASE='+case+' Create only the controlled fixture.txt artifact. Both good and bad check inputs are intentional. Review verifies committed fixture shape; actual declared checks independently gate landing.'),
            ('Declared files', 'fixture.txt'), ('Checks (one per line', check), ('Base ref', 'refs/heads/main')),
            deadline=time.monotonic()+180)
        def launched():
            for path in product.control.glob('*/launched.json'):
                value = read_json(path)
                if value and value['record_id'] == 'c2-builder':
                    return value
            return None
        launch = lib.wait_for(launched, 'actual native managed policy builder', 90)
        handle = launch['transport']['mailbox_handle']
        def accepted():
            for worker in (registry(runtime) or {}).get('dispatch', {}).get('workers', {}).values():
                if worker.get('mailbox_handle') == handle and worker['phase'] == 'accepted':
                    return worker
            return None
        worker = lib.wait_for(accepted, 'actual ACCEPTED report intake', 60)
        worker_command(product, handle, 'prepare')
        item = lib.wait_for(lambda: landing_for(product, worker['worker_id']), 'actual landing request intake', 30)
        initial_decision = approve_landing(product, worker)
        if case in ('failed', 'missing', 'stale'):
            def held():
                current = landing_for(product, worker['worker_id'])
                return current if current and (current.get('hold') or {}).get('code') == 'check_'+case else None
            blocked = lib.wait_for(held, 'declared-check hold independent of review', 90)
            assert not blocked.get('grants'), 'declared check failure/missing/stale evidence granted'
            result['initial_hold'] = blocked
            if MODES[mode][1]:
                approved = lib.wait_for(lambda: next((review for review in registry(runtime)['dispatch'].get('reviews', {}).values()
                                                     if review['builder_worker_id'] == worker['worker_id'] and review['status'] == 'approved'), None),
                                        'real reviewer approval still cannot override declared-check hold', 90)
                assert not landing_for(product, worker['worker_id']).get('grants')
                result['approved_review_did_not_override_checks'] = approved
            if case == 'failed':
                def rework():
                    observations = worker_observations(product, handle)
                    return [event for event in observations['events'] if event['kind'] == 'rework_received'
                            and 'review_id' not in event['payload']]
                first = lib.wait_for(rework, 'real check-only rework delivery without reviewer dependency', 60)
                assert len(first) == 1 and first[0]['payload']['failed_checks']
                worker_command(product, handle, 'repeat-ready')
                lib.idle(2)
                assert len(rework()) == 1, 'unchanged revision issued duplicate check-only rework'
                result['check_only_rework'] = first
                product.capture(mode+'-failed-check-only-repair')
                worker_command(product, handle, 'repair')
                approve_landing(product, worker)
            else:
                assert not [event for event in worker_observations(product, handle)['events']
                            if event['kind'] == 'rework_received' and 'review_id' not in event['payload']], 'missing/stale evidence fabricated failed-check rework'
                product.capture(mode+'-'+case+'-hold')
                worker_command(product, handle, 'run-current-check')
        def landed():
            current = landing_for(product, worker['worker_id'])
            return current if current and current['status'] == 'landed' else None
        # The release worker starts only after approval. Allow its native launch
        # and the separately bounded ACCEPTED, grant ACK and result intake stages.
        final = lib.wait_for(landed, 'real release-manager grant, expected-old Git landing and report intake', 90 + 3 * 120)
        if case in ('missing', 'stale'):
            assert final['id'] == blocked['id'] and final['request'] == blocked['request'], 'check repair replaced the existing landing request'
            approval = final['approval']
            assert approval['gate_id'] == initial_decision['id'] and approval['gate_revision'] == initial_decision['revision'] and approval['at_ms'] == initial_decision['answer']['at_ms'], 'check repair changed the exact existing owner decision'
            result['repaired_existing_request'] = {'landing_id': final['id'], 'unchanged_request': True,
                                                   'unchanged_owner_approval': True}
        proof = final['proof']
        assert proof['mode'] == mode and proof['artifact_revision'] == final['request']['source_revision']
        assert git(runtime, product.repository, 'rev-parse', 'refs/heads/main') == final['request']['source_revision']
        authority = registry(runtime)
        builder = authority['dispatch']['workers'][worker['worker_id']]
        reviews = [review for review in authority['dispatch'].get('reviews', {}).values()
                   if review['builder_worker_id'] == worker['worker_id']]
        if mode == 'review_disabled':
            assert not reviews and 'review_id' not in proof
            assert not [gate for gate in authority['dispatch']['gates'].values()
                        if gate.get('worker_id') == worker['worker_id'] and gate['kind'] == 'reviewer_unavailable']
        else:
            reviewed = next(review for review in reviews if review['review_id'] == proof['review_id'])
            assert reviewed['status'] == 'approved' and reviewed['reviewer_worker_id'] != worker['worker_id']
            assert (reviewed['builder_family'] != reviewed['reviewer_family']) == (mode == 'cross_family_review')
        if case == 'empty':
            assert not proof['check_refs'] and not builder.get('check_results')
        else:
            assert len(proof['check_refs']) == 1
            check_result = builder['check_results']['fixture']
            assert check_result['exit_code'] == 0 and check_result['head'] == proof['artifact_revision']
        result['landing'] = final
        result['worker_observations'] = {path.parent.name: read_json(path) for path in product.control.glob('*/observations.json')}
        grants = [event['reply'] for value in result['worker_observations'].values()
                  for event in value['events'] if event['kind'] == 'reply' and event['reply']['kind'] == 'landing_grant']
        assert grants, 'no release manager consumed real immutable grant'
        for grant in grants:
            if mode == 'review_disabled':
                assert all(key not in grant['payload'] for key in ('review_id', 'reviewer_family'))
                assert 'review_id' not in grant['payload']['proof']
        result['checks'].append('actual native task/check/review policy/grant/Git landing/report path: '+mode+' / '+case)
        result['status_scope'] = 'hybrid genuine Native OMP coordinator with deterministic actual managed-terminal task/check/review behavior; NOT provider-backed task/review qualification'
        product.capture(mode+'-'+case+'-landed')
        product.hold()
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        if worker_health in lib.WAKERS:
            lib.WAKERS.remove(worker_health)
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_diagnostics'] = window_diagnostics(runtime, 'policy-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        if worker_health in lib.WAKERS:
            lib.WAKERS.remove(worker_health)
        product.close()
    return result


def product_policy(base, root, evidence, processes, lib, args):
    unavailable = prerequisites()
    if unavailable:
        return unavailable
    if args.provider_readiness:
        return product_provider_readiness(base, root, evidence, processes, lib, args)
    unavailable = provider_prerequisite(args, coordinator=True)
    if unavailable:
        return unavailable
    modes, cases = args.policy_modes.split(','), args.policy_cases.split(',')
    if len(set(modes)) != len(modes) or any(mode not in MODES for mode in modes):
        raise ValueError('--policy-modes requires unique '+','.join(MODES))
    valid_cases = ('passed', 'failed', 'missing', 'stale', 'empty')
    if len(set(cases)) != len(cases) or any(case not in valid_cases for case in cases):
        raise ValueError('--policy-cases requires unique '+','.join(valid_cases))
    cells = {}
    result = {'status': 'failed', 'cells': cells,
              'provider_qualification': {'status': 'unavailable', 'reason': 'deterministic native workers are not provider-backed task/review proof; use approved auth-in-place ordinary readiness action separately'},
              'selected_matrix': {'modes': modes, 'checks': cases},
              'unverified_matrix': ['explicit coordinator review proposal refusal', 'reviewer absent/unavailable matrix',
                                    'immutable pre-cutover outstanding-grant drain/block migration', 'actual provider-backed review families']}
    for mode in modes:
        for case in cases:
            cells[mode+'/'+case] = policy_cell(base, root, evidence, processes, lib, args, mode, case)
    if all(cell['status'] == 'passed' for cell in cells.values()):
        result['status'] = 'passed'
    result['status_scope'] = 'hybrid genuine Native OMP coordinator with selected deterministic managed-worker cells only; NOT provider-worker qualification; remaining acceptance is explicit above'
    return result


def product_legacy_setup(base, root, evidence, processes, lib, args):
    from native_smoke import baseline_source
    archive_root = base/'legacy-setup-source'
    archive_root.mkdir()
    legacy = baseline_source(args.legacy_archive, archive_root)
    product = Product(base, legacy, evidence, processes, lib, 'setup-legacy-update-product', args)
    product.legacy_source = True
    result, runtime = product.result, product.runtime
    result['archive'] = {'path': str(args.legacy_archive.resolve()),
                         'sha256': hashlib.sha256(args.legacy_archive.read_bytes()).hexdigest(),
                         'provenance': 'Caller verifies prior-version source identity; hash alone does not authenticate a commit'}
    try:
        product.start(installed=True)
        ui = product.ui
        pane = ui('open', kind='spawn.spawner')
        lib.wait_for(lambda: spawn_authority(runtime), 'prior-version native SPAWN authority creation', 30)
        ui.preference(pane, page='setup')
        ui.preference(pane, row='setup-add-local')
        original = lib.wait_for(lambda: saved_records(runtime), 'prior-version ordinary manually added record', 30)
        assert len(original) == 1
        legacy_record_id = original[0]['id']
        # Complete the old ordinary editor's review gate before testing adoption.
        # A newly added placeholder has no command and is not a configured route.
        ui.preference(pane, page='agents')
        for label, key, value, expected in (
            ('Command', 'command', sys.executable, sys.executable),
            ('Arguments', 'arguments', shlex.join([str(product.worker), str(product.control), legacy_record_id]),
             [str(product.worker), str(product.control), legacy_record_id]),
            ('Working directory', 'cwd', str(product.repository), str(product.repository)),
        ):
            ui.preference(pane, label=label, value=value)
            lib.wait_for(lambda: next((row for row in saved_records(runtime)
                                      if row['id'] == legacy_record_id and row.get(key) == expected), None),
                         'durable prior-version ordinary edit '+key, 30)
        ui.preference(pane, row='approve-'+legacy_record_id)
        original = lib.wait_for(lambda: saved_records(runtime) if all(
            row.get('command') == sys.executable and not row.get('review_required')
            for row in saved_records(runtime)) else None, 'prior-version configured and explicitly approved ordinary record', 30)
        assert 'setup' not in spawn_authority(runtime), 'legacy source already has setup; select a real prior-version source'
        product.initialize_orch()
        assert 'setup' not in registry(runtime), 'legacy ORCH source already has setup'
        result['old_authorities'] = {'spawn': spawn_authority(runtime), 'orch': registry(runtime)}
        product.capture('actual-prior-version-native-config')

        # Native installer replaces actual owned installed packages, preserving
        # their existing data paths. No final authority state is copied or seeded.
        updated = runtime.root/'updated-packages'
        updated.mkdir()
        product.spawn, product.orch = updated/'SPAWN', updated/'ORCH+'
        instrument(root/'plugins/tern/SPAWN', product.spawn,
                   {'orch_kv': str(runtime.config/'plugin-data/orchplus/kv.json')})
        instrument(root/'plugins/tern/ORCH+', product.orch, {})
        for package in (product.spawn, product.orch):
            runtime.command('plugin', 'install', package, '--force', '--json')
        product.legacy_source = False
        product.open_spawn()
        assert saved_records(runtime) == original, 'native update destroyed existing records'
        setup = lib.wait_for(lambda: ui.machine(product.controller, 'orchplus.setup'), 'updated native existing-setup projection', 30)
        assert setup['setup']['review_existing'] is True, 'existing ORCH authority was treated as destructive first use'
        assert spawn_authority(runtime).get('setup_adoption_required') is True
        pane = product.spawn_pane
        ui.preference(pane, row='managed-existing', value=legacy_record_id)
        product.managed_advanced(pane)
        for field, value in {'provider': 'Codex', 'account_label': 'Adopted native legacy fixture',
                             'backend': 'local-terminal', 'executable': sys.executable,
                             'arguments': shlex.join([str(product.worker), str(product.control), legacy_record_id]),
                             'cwd': str(product.repository), 'root': str(runtime.root/'mailboxes'), 'user': ''}.items():
            ui.preference(pane, row='managed:'+field, value=value)
        ui.preference(pane, row='managed-probe')
        product.prepared_record(pane)
        product.probe_native_route(pane, legacy_record_id)
        lib.wait_for(lambda: spawn_authority(runtime)['setup']['state'] == 'adopted_existing', 'legacy adoption commit', 30)
        assert any(record['id'] == legacy_record_id for record in saved_records(runtime))
        for record in (RECORDS[0], RECORDS[3]):
            product.create_record(*record)
        # Current adoption uses grouped defaults; the baseline-only editor above
        # is intentionally not reused after the package replacement.
        product.configure_orch('review_disabled')
        lib.wait_for(lambda: registry(runtime)['setup']['state'] == 'adopted_existing', 'actual old ORCH authority adopted', 30)
        assert registry(runtime)['setup']['readiness']['state'] == 'not_run'
        product.assert_no_controller()
        result['checks'].append('old source ordinary UI creates real old stores; native package replacement migrates to explicit adoption without resetting records or creating controllers')
        result['status_scope'] = 'actual prior-version creation/native update/adoption; no outstanding grant migration claimed'
        product.capture('native-update-adopted-existing')
        product.hold()
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_traceback'] = traceback.format_exc()
        result['failure_diagnostics'] = window_diagnostics(runtime, 'legacy-setup-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        product.close()
    return result


def corrupt_store_refusal(product):
    """Negative fault only: malformed owned bytes, then exact original restore."""
    runtime = product.runtime
    path = runtime.config/'plugin-data/orchplus/kv.json'
    original = path.read_bytes()
    backup = runtime.root/'before-corrupt-store.bytes'
    backup.write_bytes(original)
    malformed = b'{"deliberate_owned_runtime_corruption":'
    evidence = {'fault': 'malformed bytes, not a seeded valid authority',
                'original_sha256': hashlib.sha256(original).hexdigest(), 'backup': str(backup)}
    try:
        path.write_bytes(malformed)
        runtime.command('plugin', 'reload', 'orchplus', '--json', check=False)
        def refused():
            tree = product.ui('surface', pane=product.controller)
            text = json.dumps(tree, ensure_ascii=False)
            return tree if 'Authority store:' in text and ('corrupt' in text.lower() or 'unreadable' in text.lower() or 'failed' in text.lower()) else None
        evidence['surface'] = product.lib.wait_for(refused, 'actual native corrupt-store refusal', 30)
        assert path.read_bytes() == malformed, 'product overwrote corrupt store with a fresh authority'
        evidence['capture'] = window_diagnostics(runtime, 'owned-corrupt-store-refusal')
    finally:
        temporary = path.with_suffix('.restore')
        temporary.write_bytes(original)
        os.replace(temporary, path)
        runtime.command('plugin', 'reload', 'orchplus', '--json')
        product.lib.wait_for(lambda: registry(runtime), 'restored exact previously-created authority bytes', 30)
    evidence['restored_defaults'] = registry(runtime)['installation_defaults']
    return evidence


def provider_session_identity(session_dir, model, worker):
    """Qualify the exact worker transcript, excluding setup diagnostic responses."""
    files = sorted(session_dir.glob('*.jsonl'))
    binding = {key: worker[key] for key in ('logical_session_id', 'worker_id',
               'worker_generation', 'work_id', 'launch_request_id', 'enrolment_token')}
    candidates = []
    for path in files:
        payload = path.read_bytes()
        lines = payload.splitlines(keepends=True)
        # Snapshot only complete append events; a concurrent final append cannot
        # become evidence merely because the worker was previously observed idle.
        rows = [json.loads(line) for line in lines if line.endswith(b'\n')]
        messages = [row['message'] for row in rows if row.get('type') == 'message']
        first_user = next((message for message in messages if message.get('role') == 'user'), None)
        if first_user is None:
            continue
        content = first_user['content']
        parts = [{'text': content}] if isinstance(content, str) else content
        transports = [json.loads(line.removeprefix('report-files-v1: '))
                      for part in parts if isinstance(part, dict)
                      for line in part.get('text', '').splitlines()
                      if line.startswith('report-files-v1: ')]
        if not any(transport.get('binding') == binding for transport in transports):
            continue
        assert len(transports) == 1, 'ambiguous native startup transport'
        candidates.append((path, payload, lines, messages, transports))
    assert len(candidates) == 1, 'missing or ambiguous owned provider session for exact worker incarnation'
    path, payload, lines, messages, transports = candidates[0]
    assert transports[0]['assignment_sha256'] == worker['assignment_sha256'], 'provider assignment differs from the actual authorized assignment'
    provider, model_id = model.split('/', 1)
    responses = [message for message in messages if message.get('role') == 'assistant']
    assert responses, 'selected route produced no actual provider response'
    assert all(message.get('provider') == provider and message.get('model') == model_id
               for message in responses), 'actual provider/model differs from the selected route'
    return {'session_file': str(path), 'snapshot_sha256': hashlib.sha256(payload).hexdigest(),
            'other_session_files_not_evidence': [str(other) for other in files if other != path],
            'provider': provider, 'model_id': model_id, 'assistant_responses': len(responses),
            'worker_id': worker['worker_id'], 'worker_generation': worker['worker_generation'],
            'exact_startup_binding': True, 'exact_assignment': True,
            'incomplete_final_event_excluded': bool(lines and not lines[-1].endswith(b'\n'))}


def provider_readiness_cell(base, root, evidence, processes, lib, args, mode):
    product = Product(base, root, evidence, processes, lib, 'provider-readiness-'+mode, args, provider=True)
    result, runtime = product.result, product.runtime
    result.update(mode=mode, explicit_provider_consent=True, automatic_native_permission_answers=False)
    try:
        # Real installed copies, not development links, bind capture endpoints,
        # source observation and this actual provider run to the same packages.
        product.start(installed=True)
        product.open_spawn()
        required = {'c2-builder', 'c2-release', MODES[mode][3]}
        for record in RECORDS:
            if record[0] in required:
                product.create_record(*record)
        product.initialize_orch()
        product.configure_orch(mode)
        product.claim()
        product.capture('provider-'+mode+'-saved-policy')
        ui, pane = product.ui, product.controller
        ui('action', pane=pane, action='plugin.orchplus.orch_readiness')
        product.capture('provider-'+mode+'-explicit-readiness-consent')
        ui.choose('Optional readiness', 'Run real readiness exercise')
        deadline = time.monotonic()+900
        observed_agents, observed_workers, observed_identities, captured, approved = {}, {}, {}, set(), set()
        result['native_worker_observations'] = observed_workers
        last_phase = None
        while time.monotonic() < deadline:
            runtime.assert_running()
            state = registry(runtime)
            readiness = state['setup']['readiness']
            if readiness['state'] == 'failed':
                raise AssertionError('actual product readiness failed: '+readiness['summary'])
            agents = ui('agents')
            for agent in agents:
                observed_agents[str(agent['pane'])] = agent
                if agent.get('delivery_error'):
                    raise AssertionError('native managed startup delivery refused: '+agent['delivery_error'])
            waiting = [agent for agent in agents if agent['state'] == 'waiting_input']
            if waiting:
                # Never approve native permission/auth/billing questions. Expose
                # the exact owned window for Main, with no retry or extra launch.
                result['native_input_required'] = waiting
                if 'native-input' not in captured:
                    product.capture('provider-native-input-required')
                    captured.add('native-input')
                product.metadata('provider-native-input-required')
                lib.idle(.5)
                continue
            workers = state.get('dispatch', {}).get('workers', {})
            native = {str(agent['pane']): agent for agent in agents}
            for worker_id, worker in workers.items():
                observed_identities[worker_id] = worker
                binding = worker.get('pane_binding') or {}
                agent = native.get(binding.get('pane_id'))
                if agent and agent.get('model') and agent.get('command'):
                    observed_workers[worker_id] = {'record_id': worker['record_id'],
                                                   'binding': binding, 'native_agent': agent}
            builders = [worker for worker in workers.values() if worker['record_id'] == 'c2-builder']
            builder = builders[0] if len(builders) == 1 else None
            item = landing_for(product, builder['worker_id'], state) if builder else None
            phase = 'landed' if item and item['status'] == 'landed' else 'decision' if item and item.get('gate_id') else 'worker-activity' if builders else 'assignment'
            if phase != last_phase:
                product.capture('provider-'+mode+'-'+phase)
                last_phase = phase
            if item and item.get('gate_id'):
                gate = state['dispatch']['gates'][item['gate_id']]
                if gate['phase'] == 'pending':
                    product.metadata('provider-awaiting-owner-landing')
                    if args.provider_approve_landing and gate['id'] not in approved:
                        # This is the same displayed native owner question. It
                        # is restricted to the actual owned readiness repository.
                        requested = Path(item['request']['repo_ref']).resolve()
                        assert requested.is_relative_to((runtime.config/'plugin-data/orchplus').resolve())
                        assert requested.name.startswith('readiness-') and item['request']['target_ref'] == 'refs/heads/main'
                        result.setdefault('owner_decisions', []).append(approve_landing(product, builder, expected_item=item))
                        approved.add(gate['id'])
            if readiness['state'] == 'passed':
                assert item and item['status'] == 'landed', 'readiness passed without actual matching landing'
                repository = Path(item['request']['repo_ref']).resolve()
                assert repository.is_relative_to((runtime.config/'plugin-data/orchplus').resolve())
                assert git(runtime, repository, 'show', 'refs/heads/main:readiness.txt') == 'ready'
                assert git(runtime, repository, 'rev-parse', 'refs/heads/main') == item['request']['source_revision']
                proof = item['proof']
                assert proof['mode'] == mode and proof['check_refs']
                if mode == 'review_disabled':
                    assert 'review_id' not in proof
                    assert not [review for review in state['dispatch'].get('reviews', {}).values()
                                if review['builder_worker_id'] == builder['worker_id']]
                else:
                    review = state['dispatch']['reviews'][proof['review_id']]
                    assert review['status'] == 'approved'
                    assert review['reviewer_worker_id'] != builder['worker_id']
                    assert review['builder_family'] == 'openai'
                    assert review['reviewer_family'] == ('anthropic' if mode == 'cross_family_review' else 'openai')
                    result['review'] = review
                landed_grants = [grant for grant in item['grants']
                                 if (grant.get('result') or {}).get('outcome') == 'landed']
                assert len(landed_grants) == 1, 'actual release-manager landed result is missing or ambiguous'
                roles = {'builder': (builder['worker_id'], 'c2-builder', 'openai-codex/gpt-6-astra'),
                         'release_manager': (landed_grants[0]['worker_id'], 'c2-release', 'openai-codex/gpt-6-astra')}
                if mode != 'review_disabled':
                    roles['reviewer'] = (review['reviewer_worker_id'], MODES[mode][3],
                                         'anthropic/claude-opus-5-5' if mode == 'cross_family_review' else 'openai-codex/gpt-6-astra')
                role_observations = {}
                for role, (worker_id, record_id, model) in roles.items():
                    observed = observed_workers.get(worker_id)
                    assert observed and observed['record_id'] == record_id, 'missing exact native worker binding for '+role
                    session_dir = runtime.root/'provider-sessions'/record_id
                    identity = provider_session_identity(session_dir, model, observed_identities[worker_id])
                    argv = shlex.split(observed['native_agent']['command'])
                    assert argv.count('--model') == 1 and argv[argv.index('--model')+1] == model, 'actual selected provider command mismatch for '+role
                    assert argv.count('--session-dir') == 1 and Path(argv[argv.index('--session-dir')+1]).resolve() == session_dir.resolve(), 'actual native session storage mismatch for '+role
                    role_observations[role] = {'worker_id': worker_id, 'provider_identity': identity, **observed}
                result['native_role_observations'] = role_observations
                result.update(readiness=readiness, landing=item,
                              observed_native_agents=list(observed_agents.values()),
                              status_scope='actual native provider task, helper checks, configured review mode, ordinary owner decision and release-manager landing with Git readback')
                product.capture('provider-'+mode+'-final-landing')
                break
            lib.idle(.5)
        else:
            raise AssertionError('bounded actual provider readiness did not finish; inspect retained native workflow/permission gates; no retry or provider fallback was attempted')
        product.hold()
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = f'{type(error).__name__}: {error}'
        result['failure_diagnostics'] = window_diagnostics(runtime, 'provider-readiness-failure')
        if hasattr(product, 'ui'):
            product.hold()
    finally:
        product.close()
    return result


def product_provider_readiness(base, root, evidence, processes, lib, args):
    modes = args.policy_modes.split(',')
    if len(set(modes)) != len(modes) or any(mode not in MODES for mode in modes):
        raise ValueError('--policy-modes requires unique '+','.join(MODES))
    if not shutil.which('omp') or not args.provider_agent_dir.is_absolute() or not args.provider_agent_dir.is_dir():
        return {'status': 'unavailable', 'reason': 'explicit provider mode requires installed OMP and the approved absolute existing native agent directory; no credentials are copied'}
    cells = {}
    for mode in modes:
        cells[mode] = provider_readiness_cell(base, root, evidence, processes, lib, args, mode)
        if cells[mode]['status'] != 'passed':
            break  # Auth/billing/permission failures never trigger another provider run.
    return {'status': 'passed' if len(cells) == len(modes) and all(cell['status'] == 'passed' for cell in cells.values()) else 'failed',
            'cells': cells, 'provider_qualification': True,
            'status_scope': 'actual fixed product readiness task for selected modes; failed/missing/stale/empty check matrix is the separately labelled deterministic native scenario'}


def product_conversation_journey(base, root, evidence, processes, lib, args, *, mode='fixture'):
    """Conversation-first native journey; parent registers and runs after freeze.

    Register fixture and explicitly approved provider CLI modes separately. Only
    mode='provider' uses args.provider_agent_dir authentication in place and OMP.
    Common args are Product's capture_desktop/capture_hold/capture_start_hold/
    control_metadata. Neither mode answers native permission prompts or retries uncertain input.
    Common checks retain attachment/held-source/START boundaries without claiming
    task completion or landing. Verified local-terminal and Native OMP routes both
    support coordinators; provider identity/reasoning still require provider mode.
    """
    if mode not in ('fixture', 'provider'):
        raise ValueError('conversation journey mode must be fixture or provider')
    unavailable = prerequisites()
    if unavailable:
        return unavailable
    provider = mode == 'provider'
    auth = getattr(args, 'provider_agent_dir', None)
    if provider and (not shutil.which('omp') or auth is None
                     or not Path(auth).is_absolute() or not Path(auth).is_dir()):
        return {'status': 'unavailable', 'reason': 'explicit provider journey requires OMP and approved existing absolute provider-agent-dir; no credential copies'}
    product = Product(base, root, evidence, processes, lib, 'conversation-journey-'+mode,
                      args, provider=provider, instrumented=False)
    result, runtime = product.result, product.runtime
    result.update(journey_mode=mode, explicit_provider_consent=provider,
                  automatic_native_permission_answers=False,
                  status_scope=('full native coordinator and worker conversation journey; attachment, held source and explicit project START; not task completion or landing'
                                if provider else 'terminal worker conversation, coordinator selection cancellation, attachment, held source and explicit project START; provider behavior requires separate provider journey'),
                  source_evidence={name: hashlib.sha256((root/'plugins/tern/ORCH+'/name).read_bytes()).hexdigest()
                                   for name in ('conversation_window.luau', 'source_window.luau',
                                                'picker_window.luau', 'setup_window.luau', 'views.luau')})
    result['coordinator_eligibility_source'] = {
        'path': 'plugins/tern/SPAWN/managed_setup.luau',
        'sha256': hashlib.sha256((root/'plugins/tern/SPAWN/managed_setup.luau').read_bytes()).hexdigest(),
        'contract': 'Verified native-agent and local-terminal setup grant coordinator-control-v1; labels alone do not.'}
    hold_started = False
    try:
        product.start(installed=True)
        ui = product.ui
        for command in (('branch', 'release-target'),
                        ('update-ref', 'refs/remotes/origin/release-target', 'HEAD'),
                        ('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/release-target'),
                        ('config', 'remote.origin.url', 'https://example.invalid/offline-fixture.git'),
                        ('switch', '-c', 'feature/walkthrough')):
            git(runtime, product.repository, *command)

        def begin(seconds):
            # Only a new user operation gets a new deadline, never a retry.
            ui.operation_deadline = time.monotonic()+seconds

        def wait(predicate, label, seconds=40):
            return lib.wait_for(predicate, label, ui.remaining(seconds))

        def project_named(name):
            rows = [row for row in (registry(runtime) or {}).get('dispatch', {}).get('projects', {}).values()
                    if row['name'] == name and not row.get('finished')]
            assert len(rows) <= 1, 'duplicate project name in owned journey'
            return rows[0] if rows else None

        def project_view(project_id):
            index = ui.machine(product.controller, 'orchplus.projects', 'project-index')
            return (index or {}).get('projects', {}).get(project_id)

        def checkpoint(label):
            panes = ui('panes')
            transport = [pane for pane in panes if pane.get('block') in
                         ('spawn.dispatch', 'usage.capacity', 'usage.display')]
            assert not transport, 'shared communication opened a transport pane: '+repr(transport)
            result.setdefault('pane_observations', {})[label] = panes
            product.capture(label)
            assert 'shot' in result['captures'][label], 'native capture failed at '+label

        def accepted(record_id):
            rows = [row for row in registry(runtime)['dispatch']['workers'].values()
                    if row['record_id'] == record_id]
            assert len(rows) <= 1, 'one selection launched duplicate workers'
            for agent in ui('agents'):
                assert not agent.get('delivery_error'), agent.get('delivery_error')
                if agent.get('state') == 'waiting_input':
                    result.setdefault('native_input_required', {})[str(agent['pane'])] = agent
                    if 'native-permission-required' not in result['captures']:
                        product.capture('native-permission-required')
                    product.metadata('provider-native-input-required')
            if not provider:
                for path in product.control.glob('*/error.json'):
                    assert not read_json(path), read_json(path)
            return rows[0] if rows and rows[0]['phase'] == 'accepted' and rows[0].get('pane_binding') else None

        begin(60)
        ui('action', action='plugin.orchplus.new_orchestration')
        prerequisite_form = ui.form_pane('Complete agent setup first')
        assert not (registry(runtime) or {}).get('sessions'), 'missing agent setup created an orchestration'
        checkpoint('missing-spawn-setup-blocks-creation')
        ui.mouse_click(prerequisite_form, 'Set up agents in SPAWN')

        product.open_spawn()
        original_worker = product.worker
        if getattr(args, 'stop_after_startup_exit', False):
            assert not provider, 'startup-exit smoke must not use provider credentials'
            product.worker = runtime.root/'known-startup-exit.py'
            product.worker.write_text('raise SystemExit(2)\n')
            result['startup_exit_fixture'] = {'path': str(product.worker), 'sha256': hashlib.sha256(product.worker.read_bytes()).hexdigest(),
                                              'expected_exit': 2, 'provider': False}
        coordinator = product.create_record('c2-release', 'OMP', one_action=True)
        product.worker = original_worker
        child = product.create_record('c2-builder', 'Codex', one_action=True)
        authority = spawn_authority(runtime)
        assert len(authority['config']['hosts']) == 1, 'local-first setup added another machine'
        assert all(row['backend'] == ('native-agent' if provider else 'local-terminal')
                   for row in (coordinator, child))
        assert all('coordinator-control-v1' in record['mailbox']['capabilities'] for record in (coordinator, child))
        checkpoint('conversation-local-first-spawn')

        begin(90)
        ui('action', action='plugin.orchplus.open')
        def empty_panel():
            panes = [pane['pane'] for pane in ui('panes') if pane.get('block') == 'orchplus.orchestrator']
            assert len(panes) <= 1, 'first-use entry opened duplicate orchestration panels'
            return panes[0] if panes else None
        product.controller = wait(empty_panel, 'ordinary first-use orchestration panel')
        defaults_form = product.open_defaults()
        initial_defaults = registry(runtime)['installation_defaults']
        assert initial_defaults.get('defined') is False
        checkpoint('defaults-before-first-save')
        ui.mouse_click(defaults_form, 'SAVE AS DEFAULT ORCHESTRATION SETTINGS')
        defined = wait(lambda: (value if (value := registry(runtime)['installation_defaults']).get('defined') is True else None),
                       'first unchanged explicit default save')
        changed_defaults = {key: {'before': initial_defaults['policy'].get(key), 'after': defined['policy'].get(key)}
                            for key in initial_defaults['policy'].keys() | defined['policy'].keys()
                            if initial_defaults['policy'].get(key) != defined['policy'].get(key)}
        assert not changed_defaults, 'saving unchanged defaults altered policy: '+json.dumps(changed_defaults)
        product.assert_no_controller()
        defaults_form = product.open_defaults()
        assert next(pane for pane in ui('panes') if pane['pane'] == defaults_form)['title'] == 'Edit Default Settings'
        checkpoint('defaults-after-first-save')
        ui.mouse_click(defaults_form, 'Close')
        wait(lambda: all(pane['pane'] != defaults_form for pane in ui('panes')),
             'settings pane closed before orchestration creation')

        if getattr(args, 'stop_after_custom_settings', False):
            assert not provider, 'custom-settings smoke must not use provider credentials'
            begin(120)
            defaults_before = json.loads(json.dumps(registry(runtime)['installation_defaults']))
            product.create_orchestration('Custom settings check', reuse=True, custom=True)
            # No owner action between Create and the actual instance editor.
            form = ui.form_pane('Orchestration settings')
            checkpoint('custom-settings-opened-automatically')
            state = registry(runtime)
            assert len(state['sessions']) == 1 and not state['dispatch']['workers'], 'custom setup launched or duplicated an orchestration'
            logical = next(iter(state['sessions']))
            ui.click_match(form, 'Agents and Routing')
            ui.edit_field(form, 'Concurrent work limit', '3')
            ui.mouse_click(form, 'SAVE FOR THIS ORCHESTRATION INSTANCE ONLY')
            wait(lambda: registry(runtime)['dispatch']['policies'][logical]['concurrency_limit'] == 3,
                 'actual instance writer saves the edited policy')
            wait(lambda: all(pane['pane'] != form for pane in ui('panes')), 'instance Save closes its native editor')
            state = registry(runtime)
            assert state['installation_defaults'] == defaults_before, 'instance settings overwrote reusable defaults'
            assert not state['dispatch']['workers'], 'custom settings started an agent'
            result['saved_instance_policy'] = state['dispatch']['policies'][logical]
            checkpoint('custom-settings-saved-only-to-instance')
            result['checks'].append('Custom settings automatically opens the instance editor; instance Save does not change defaults or launch work')
            result['status'] = 'passed'
            result['status_scope'] = 'focused actual native Custom continuation and instance-save boundary; no provider or task qualification'
            ui.operation_deadline = None
            return result

        if getattr(args, 'stop_after_startup_exit', False):
            begin(120)
            ui.mouse_click(product.controller, 'Edit Default Settings')
            form = ui.form_pane('Edit Default Settings')
            ui.click_match(form, 'Continuity')
            checkpoint('startup-calculated-threshold')
            ui.mouse_click(form, 'Close')
            wait(lambda: all(pane['pane'] != form for pane in ui('panes')), 'formula inspection closes without saving')
            product.create_orchestration('Startup display', reuse=True)
            ui.pick_agent('Choose your orchestrator', 'OMP · '+coordinator['account_label'])
            def failed_start_visible():
                rows = list(surface_nodes(ui('surface', pane=product.controller).get('main')))
                return any('exit 2' in span.get('t', '') and 'error' in (span.get('s') or '').split()
                           for row in rows if row.get('k') == 'text' for span in row.get('p', {}).get('spans', []))
            wait(failed_start_visible, 'actual bound exit 2 replaces startup progress with a visible error')
            workers = list(registry(runtime)['dispatch']['workers'].values())
            assert len(workers) == 1 and workers[0]['record_id'] == coordinator['id'], 'failed startup was replayed or substituted'
            assert workers[0].get('pane_binding'), 'failed-start feedback lacks its actual native pane binding'
            result['failed_start_worker'] = workers[0]
            checkpoint('startup-actual-exit-two')
            result['checks'].append('one real terminal startup exits 2; exact bound error shown, original work retained and no replacement launched')
            result['status'] = 'passed'
            result['status_scope'] = 'focused native startup-exit and calculated-formula surface; no provider, enrollment, task or broad qualification'
            ui.operation_deadline = None
            return result

        if getattr(args, 'stop_after_settings', False):
            assert not provider, 'settings-only smoke must not use provider credentials'
            baseline = json.loads(json.dumps(registry(runtime)['installation_defaults']))
            threshold = max(1, baseline['policy']['rollover_threshold_pct']-1)
            first_board, second_board = (product.repository/name for name in ('First board.md', 'Selected board.md'))
            first_board.write_text('# First board\n\n## Todo\n')
            second_board.write_text('# Selected board\n\n## Todo\n')

            def field_text(pane, label):
                surface = ui('surface', pane=pane)
                fields = [node for node in surface_nodes(surface.get('main'))
                          if node.get('k') == 'field' and node.get('p', {}).get('label') == label]
                controls = [node for field in fields for node in surface_nodes(field)
                            if node.get('k') in ('input', 'editor')]
                assert len(controls) <= 1, 'ambiguous native field '+label
                return controls[0].get('p', {}).get('text') if controls else None

            def change_settings(pane):
                ui.click_match(pane, 'Agents and Routing')
                ui.select_field(pane, 'Preferred Worker', 'c2-builder')
                # A saved preference does not launch its eligible agent.
                ui.select_field(pane, 'Preferred Orchestrator', 'c2-release')
                ui.edit_field(pane, 'Concurrent work limit', '3')
                ui.switch_field(pane, 'Maximum quota-evidence age', True)
                ui.edit_field(pane, 'Maximum evidence age', '2')
                ui.switch_field(pane, 'Maximum quota-evidence age', False)
                ui.click_match(pane, 'Agents and Routing')
                ui.click_match(pane, 'Continuity')
                ui.switch_field(pane, 'Automatic worker rollover', False)
                ui.switch_field(pane, 'Automatic worker rollover', True)
                checkpoint('settings-native-calculated-rollover')
                ui.select_field(pane, 'Reported context threshold', 'percentage')
                ui.edit_field(pane, 'Percentage override', str(threshold))
                ui.click_match(pane, 'Continuity')
                ui.click_match(pane, 'General')
                ui.edit_field(pane, 'Board file location', str(first_board))
                ui.mouse_click(pane, 'Browse')
                ui.mouse_click(pane, second_board.name)
                wait(lambda: field_text(pane, 'Board file location') == str(second_board),
                     'native Browse returns the selected file into its field')
                checkpoint('settings-native-browse-selected')
                ui.click_match(pane, 'General')

            begin(180)
            ui.mouse_click(product.controller, 'Edit Default Settings')
            form = ui.form_pane('Edit Default Settings')
            change_settings(form)
            ui.click_match(form, 'Glitch Integration')
            checkpoint('settings-native-work-status-and-divider')
            ui.click_match(form, 'Glitch Integration')
            ui.click_match(form, 'Agents and Routing')
            ui.edit_field(form, 'Concurrent work limit', 'invalid')
            ui.mouse_click(form, 'Close')
            wait(lambda: all(pane['pane'] != form for pane in ui('panes')),
                 'Close exits an invalid unsaved draft')
            assert registry(runtime)['installation_defaults'] == baseline, 'Close saved or altered the discarded draft'
            result['checks'].append('native Close discards an invalid edited draft without changing defaults')

            begin(180)
            ui.mouse_click(product.controller, 'Edit Default Settings')
            form = ui.form_pane('Edit Default Settings')
            change_settings(form)
            ui.click_match(form, 'Agents and Routing')
            ui.edit_field(form, 'Concurrent work limit', 'invalid')
            ui.mouse_click(form, 'SAVE AS DEFAULT ORCHESTRATION SETTINGS')
            def blocking_field():
                fields = [node for node in surface_nodes(ui('surface', pane=form).get('main'))
                          if node.get('k') == 'field' and node.get('p', {}).get('label') == 'Concurrent work limit']
                return fields[0] if len(fields) == 1 and fields[0]['p'].get('error') and fields[0]['p'].get('tone') == 'error' else None
            wait(blocking_field, 'invalid settings identify the blocking native field')
            assert field_text(form, 'Concurrent work limit') == 'invalid', 'failed save discarded the entered draft'
            assert registry(runtime)['installation_defaults'] == baseline, 'invalid draft changed saved defaults'
            checkpoint('settings-native-blocking-field')
            ui.edit_field(form, 'Concurrent work limit', '3')
            ui.mouse_click(form, 'SAVE AS DEFAULT ORCHESTRATION SETTINGS')
            def repaired_save():
                saved = registry(runtime)['installation_defaults']
                p = saved['policy']
                return saved if (saved['revision'] > baseline['revision']
                                 and p['preferred_worker_record'] == 'c2-builder'
                                 and p['preferred_orchestrator_record'] == 'c2-release'
                                 and p['concurrency_limit'] == 3 and p['quota_max_age_ms'] == 0
                                 and p['auto_rollover'] is True and p['rollover_threshold_pct'] == threshold) else None
            saved = wait(repaired_save, 'native selections, switches and text persist through the real defaults writer')
            wait(lambda: all(pane['pane'] != form for pane in ui('panes')), 'successful Save exits its form')
            assert not registry(runtime)['sessions'] and not (registry(runtime).get('dispatch') or {}).get('workers'), 'settings started orchestration work'
            ui.mouse_click(product.controller, 'Edit Default Settings')
            form = ui.form_pane('Edit Default Settings')
            ui.click_match(form, 'Agents and Routing')
            assert field_text(form, 'Concurrent work limit') == '3', 'reopen lost the actual saved field value'
            checkpoint('settings-native-saved-and-reopened')
            ui.mouse_click(form, 'Close')
            wait(lambda: all(pane['pane'] != form for pane in ui('panes')), 'reopened settings Close exits normally')
            result['saved_settings'] = saved
            result['checks'].append('real native preference selection, rollover/age switches, Browse, save and reopen; no work launched')
            result['status'] = 'passed'
            result['status_scope'] = 'focused actual native settings repair only; no conversation, WORK/reload, provider or broad qualification'
            ui.operation_deadline = None
            return result

        begin(90)
        product.create_orchestration('Conversation desk', reuse=True)
        parent = wait(lambda: project_named('Conversation desk'), 'automatic named project')
        parent_id = parent['orch_project_id']
        assert parent['started'] is False
        picker = ui.agent_picker('Choose your orchestrator')
        result['orchestrator_picker'] = ui('surface', pane=picker)
        checkpoint('conversation-orchestrator-picker')
        orchestrator = None
        if provider:
            begin(180)
            ui.pick_agent('Choose your orchestrator', 'OMP · '+coordinator['account_label'])
            orchestrator = wait(lambda: accepted('c2-release'), 'actual native OMP orchestrator acceptance', 180)
            assert orchestrator['orch_project_id'] == parent_id
            assert not project_named('Conversation desk')['started'], 'conversation launch STARTed project work'
            result['orchestrator'] = orchestrator
            result['coordinator_coverage'] = {'status': 'exercised', 'route': 'ordinary saved Native OMP',
                                            'worker_id': orchestrator['worker_id']}
            checkpoint('conversation-orchestrator-connected')
        else:
            picker_nodes = list(surface_nodes(result['orchestrator_picker'].get('main')))
            assert any(node.get('k') == 'item' and not node.get('p', {}).get('disabled')
                       for node in picker_nodes), 'verified terminal coordinator was not offered'
            assert not registry(runtime)['dispatch']['workers'], 'merely opening the coordinator picker launched work'
            result['coordinator_coverage'] = {
                'status': 'not_exercised',
                'reason': 'This fixture journey deliberately cancels selection; verified terminal coordinators are eligible. Provider behavior requires provider mode.',
                'saved_records': [coordinator, child],
                'required_scenario': 'conversation-provider',
                'required_checks': ['actual provider orchestrator ACCEPTED', 'orchestrator adjacent to its panel',
                                    'exact provider/model/startup-binding evidence for coordinator and child']}
            ui.mouse_click(picker, 'Close')
            lib.wait_for(lambda: all(pane['pane'] != picker for pane in ui('panes')),
                         'Closing the native picker removes its pane before another opens', ui.remaining(10))
            assert not project_named('Conversation desk')['started']
            checkpoint('conversation-coordinator-selection-cancelled')

        begin(60)
        wait(lambda: not any(
            action.get('request', {}).get('op') in ('launch', 'mailbox_provision')
            for action in registry(runtime)['dispatch']['actions'].values()),
            'conversation launch settlement before repository selection')
        repository = product.configure_repository(product.repository, target=None)
        assert Path(repository['cwd']).resolve() == product.repository.resolve()
        assert repository['target_ref'] == 'refs/heads/release-target' and repository['queue_route'] == 'orch_queue'
        assert not project_named('Conversation desk')['started'], 'repository selection STARTed project work'
        result['selected_repository'] = repository
        checkpoint('conversation-repository-selected')
        begin(90)
        explicit_repository = product.configure_repository(product.repository, target='refs/heads/main')
        assert explicit_repository['target_ref'] == 'refs/heads/main'
        ui.command(product.controller, 'project_menu')
        ui.choose('Conversation desk', 'Settings')
        ui.choose('Project settings · Conversation desk', 'Code and merging')
        repository_form = ui.form_pane('Code and merging · Conversation desk')
        wait(lambda: any(node.get('k') == 'select' and node.get('p', {}).get('key') == 'field:target_ref'
                         and node.get('p', {}).get('value') == 'refs/heads/main'
                         for node in surface_nodes(ui('surface', pane=repository_form).get('main'))),
             'explicit merge branch retained when reopening settings')
        checkpoint('conversation-repository-explicit-target-retained')
        ui.mouse_click(repository_form, 'Back')
        result['explicit_repository'] = explicit_repository

        begin(60)
        ui.command(product.controller, 'new_conversation')
        ui.choose('Existing orchestrated project or New', 'Conversation desk')
        picker = ui.agent_picker('Choose an agent')
        tree = ui('surface', pane=picker)
        result['worker_picker'] = tree
        checkpoint('conversation-compact-picker')
        begin(180 if provider else 90)
        ui.pick_agent('Choose an agent', ('OMP' if provider else 'Codex')+' · '+child['account_label'])
        ui('focus', pane=product.controller)
        checkpoint('conversation-child-starting')
        worker = wait(lambda: accepted('c2-builder'), 'actual child conversation acceptance',
                      180 if provider else 90)
        assert worker['orch_project_id'] == parent_id and worker.get('open_conversation') is True
        panes = {str(pane['pane']): pane for pane in ui('panes')}
        controller = panes[str(product.controller)]
        adjacent = panes[orchestrator['pane_binding']['pane_id']] if provider else None
        child_pane = panes[worker['pane_binding']['pane_id']]
        if provider:
            assert adjacent['tab'] == controller['tab'], 'orchestrator is not adjacent to its panel'
        assert child_pane['tab'] != controller['tab'], 'New conversation did not open its own tab'
        assert child_pane.get('title'), 'native child title is absent'
        ui('focus', pane=product.controller)
        expected_child = None
        def hierarchy():
            nonlocal child_pane, expected_child
            current = next((pane for pane in ui('panes')
                            if str(pane['pane']) == worker['pane_binding']['pane_id']), None)
            if current is None or not current.get('title'):
                return None
            child_pane = current
            expected_child = ('OMP' if provider else 'Codex')+' · '+child['account_label']+' — '+current['title']
            surface = ui('surface', pane=product.controller)
            parent_visible, child_visible = False, False
            for node in surface_nodes((surface or {}).get('main')):
                props = node.get('p', {})
                text = ''.join(descendant.get('p', {}).get('text') or
                               ''.join(span if isinstance(span, str) else span.get('t', '')
                                       for span in descendant.get('p', {}).get('spans', []))
                               for descendant in surface_nodes(node))
                attrs = props.get('attrs', {})
                if props.get('actions', {}).get('click') and text == parent['name']:
                    parent_visible = True
                if (attrs.get('data-orchplus-command') == 'open_worker'
                        and attrs.get('data-orchplus-worker') == worker['worker_id']
                        and text == expected_child):
                    child_visible = True
            return surface if parent_visible and child_visible else None
        panel = wait(hierarchy, 'project parent and native child title')
        result['conversation_hierarchy'] = {'parent': parent, 'controller': controller,
                                            'orchestrator': adjacent, 'child': child_pane,
                                            'child_worker_id': worker['worker_id'], 'expected_child_row': expected_child, 'surface': panel}
        checkpoint('conversation-parent-child')

        # Use an existing owned ordinary terminal, or discover the ordinary
        # terminal creation command in the real native command palette.
        managed = {row.get('pane_binding', {}).get('pane_id')
                   for row in registry(runtime)['dispatch']['workers'].values()}
        def terminals():
            return [pane for pane in ui('panes')
                    if pane.get('kind') == 'terminal' and str(pane['pane']) not in managed]
        begin(60)
        available = terminals()
        if not available:
            runtime.ctl('palette', 'terminal')
            def terminal_choice():
                choices = []
                for node in native_nodes(runtime.ctl('tree').get('tree', [])):
                    if node.get('role') != 'option':
                        continue
                    labels = [child.get('text', '') for child in native_nodes(node)]
                    if any(label.casefold().strip() in ('new terminal', 'open terminal') for label in labels):
                        choices.append(node)
                assert len(choices) <= 1, 'ambiguous native terminal creation choice'
                return choices[0] if choices else None
            option = wait(terminal_choice, 'visible native terminal creation command')
            x, y, width, height = option['rect']
            assert ui.remaining(1) > 0, 'terminal creation deadline expired'
            runtime.ctl('click', str(x+width/2), str(y+height/2))
            ui.record_input({'op': 'native_palette', 'query': 'terminal', 'control': option})
            available = wait(terminals, 'ordinary terminal created')
        assert len(available) == 1, 'ambiguous owned unmanaged terminal'
        terminal = available[0]
        ui('focus', pane=terminal['pane'])
        runtime.ctl('type', json.dumps('sleep 600'))
        runtime.ctl('key', 'Enter')
        ui.record_input({'op': 'native_terminal_input', 'pane': terminal['pane'], 'text': 'sleep 600'})
        terminal = wait(lambda: next((pane for pane in terminals()
                         if pane['pane'] == terminal['pane'] and pane.get('busy') is True), None),
                        'actual busy unmanaged terminal')
        before_workers = set(registry(runtime)['dispatch']['workers'])
        ui.command(product.controller, 'attach_conversation')
        ui.choose('Attach an existing conversation — preserve its context', terminal['title'])
        ui.choose('Existing orchestrated project or New', 'Conversation desk')
        ui.choose('Conversation attached — optionally enable managed coordination',
                  'Keep existing conversation unchanged')
        attached = wait(lambda: next((row for row in project_named('Conversation desk')['associations'].values()
                         if row['pane_binding']['pane_id'] == str(terminal['pane']) and row['active']), None),
                        'persisted active passive association')
        assert set(registry(runtime)['dispatch']['workers']) == before_workers
        assert not project_named('Conversation desk')['started']
        result['passive_attachment'] = {'association': attached, 'evidence_kind': 'actual busy terminal fixture, not provider conversation'}
        checkpoint('conversation-attached-without-start')

        # Supported source bytes in the disposable execution host, not seeded
        # domain authority, live plans or a fabricated discovery response.
        plan = runtime.root/'conversation-plan.md'
        plan.write_text('# Feature: Held conversation research\n\n'
                        '### Checkpoint 1 — Discuss evidence\n'
                        '#### Task A1 — Compare the supplied facts\n'
                        '**INDEPENDENT**\n'
                        'Discuss the supplied text only. Do not edit files or run commands.\n'
                        '##### Steps\n'
                        '- [ ] Read each supplied fact.\n'
                        '- [ ] Compare only stated evidence.\n')
        result['plan_source'] = {'path': str(plan), 'sha256': hashlib.sha256(plan.read_bytes()).hexdigest()}
        begin(60)
        ui.command(product.controller, 'orchestration_menu')
        ui.choose('Orchestration', 'Add plan file…')
        plan_form = ui.form_pane('Plan file on the execution host')
        ui.edit_field(plan_form, 'Plan file on the execution host', str(plan))
        ui.mouse_click(plan_form, 'Continue')
        ui.choose('Add to which project?', 'Conversation desk')
        def imported():
            rows = [row for row in registry(runtime)['dispatch'].get('plans', {}).values()
                    if row.get('path') == str(plan)]
            assert len(rows) <= 1, 'source imported twice'
            return rows[0] if rows else None
        held = wait(imported, 'held source persisted')
        assert held['orch_project_id'] == parent_id and held.get('held') is True
        assert not project_named('Conversation desk')['started']
        projected = wait(lambda: (view if (view := project_view(parent_id)) and view.get('held_work') else None),
                         'ACTIVE project retains held work')
        assert projected['status'] == 'ACTIVE'
        assert all(not task.get('work_id') for cp in held['checkpoints'] for task in cp['tasks']), 'attachment or import launched held tasks'
        result['held_source'] = held
        checkpoint('conversation-active-with-held-source')

        begin(90)
        expected_titles = ('Held conversation research', 'Discuss evidence', 'Compare the supplied facts',
                           'Read each supplied fact.', 'Compare only stated evidence.')
        plugin_data = runtime.config/'plugin-data/orchplus'
        def synchronized_board_file():
            matches = []
            for path in plugin_data.rglob('*.md'):
                text = path.read_text()
                if all(title in text for title in expected_titles):
                    matches.append(path)
            assert len(matches) <= 1, 'automatic synchronization created duplicate linked board files'
            return matches[0] if matches and not any((plugin_data/'source-board-sync').glob('*.json')) else None
        persisted_board = wait(synchronized_board_file, 'automatic native board synchronization settled')
        ui.command(product.controller, 'project_menu')
        ui.choose('Conversation desk', 'Open ORCH+ Board')
        def board_pane():
            panes = [pane for pane in ui('panes') if pane.get('kind') == 'board']
            assert len(panes) <= 1, 'one linked plan created duplicate native boards'
            return panes[0] if panes else None
        board = wait(board_pane, 'native linked plan board')
        board_path = board['path']
        assert Path(board_path).resolve() == persisted_board.resolve(), 'Open ORCH+ Board selected another document'
        def board_text():
            text = ui('doc_read', path=board_path)
            return text if isinstance(text, str) and all(title in text for title in expected_titles) else None
        original_board = wait(board_text, 'native plan/checkpoint/task/step hierarchy')
        for lane in ('Todo', 'Doing', 'Review', 'Done'):
            assert '## '+lane in original_board, 'fresh linked board omitted a usable work lane: '+lane
        assert sum(line.startswith('## ') for line in original_board.splitlines()) == 5, 'automatic plan import multiplied the fresh fixed board columns'
        journal = runtime.config/'plugin-data/orchplus/source-board-sync'/(hashlib.sha256(board_path.encode()).hexdigest()+'.json')
        wait(lambda: not journal.exists(), 'positive native board writes settled')
        ui('focus', pane=board['pane'])
        checkpoint('live-plan-board-before-progress')
        ui('focus', pane=product.controller)
        source_context = ui('context')
        ui.mouse_click(product.controller, 'Open plan')
        source_pane = wait(lambda: next((pane for pane in ui('panes') if pane.get('path') == str(plan)), None),
                           'ORCH+ Open plan button opened the exact execution-host plan')
        assert ui('context')['host']['id'] == source_context['host']['id'], 'source opening switched execution hosts'
        result['source_link'] = {'path': str(plan), 'pane': source_pane['pane'], 'native_button_clicked': True,
                                 'execution_host': source_context['host']['id']}
        checkpoint('source-plan-opened')
        if getattr(args, 'stop_after_source_open', False):
            result['status'] = 'passed'
            result['status_scope'] = 'focused native Open plan button; later conversation/WORK/reload qualification not run'
            result['checks'] = ['actual native ORCH+ Open plan button opens its exact current source on the same execution host']
            ui.operation_deadline = None
            return result
        ui('close', pane=source_pane['pane'])
        ui('focus', pane=board['pane'])
        held_workers = set(registry(runtime)['dispatch']['workers'])
        execution_revision = imported()['plan_revision']
        def observed_source(expected_revision, after_request=None):
            receipt = ui.machine(product.controller, 'orchplus.sources', 'source-discovery') or {}
            page = receipt.get('source_page') or {}
            if not receipt.get('ok') or page.get('path') != str(plan) or page.get('revision') != expected_revision:
                return None
            if after_request is not None and receipt.get('request_id') == after_request:
                return None
            payload = page.get('bytes')
            if not isinstance(payload, str) or page.get('offset') != 0 or len(payload.encode()) != page.get('total_bytes'):
                return None
            assert hashlib.sha256(payload.encode()).hexdigest() == page.get('sha256'), 'native source observation is incomplete'
            source = json.loads(payload)
            assert source['path'] == str(plan) and source['plan']['plan_revision'] == expected_revision
            return receipt
        plan.write_text(plan.read_text()+'\n## Progress\nDiscussed the facts; no task completion is declared here.\n')
        progress_revision = hashlib.sha256(plan.read_bytes()).hexdigest()
        progress_read = wait(lambda: observed_source(progress_revision), 'live Progress-only source observation')
        # The next independent poll starts only after the previous mirror job ends.
        wait(lambda: observed_source(progress_revision, progress_read['request_id']), 'completed Progress-only synchronization cycle')
        assert board_text() == original_board and not journal.exists(), 'Progress prose rewrote or duplicated native board cards'
        plan.write_text(plan.read_text().replace('- [ ] Read each supplied fact.', '- [x] Read each supplied fact.'))
        step_revision = hashlib.sha256(plan.read_bytes()).hexdigest()
        wait(lambda: observed_source(step_revision), 'live explicit step completion observation')
        def checked_step():
            text = board_text()
            for line in (text or '').splitlines():
                if not line.startswith('- [x] ') or 'Read each supplied fact.' not in line:
                    continue
                query = parse_qs(line.partition('(tern://orchplus-plan?')[2].partition(')')[0])
                if query.get('projection') == ['2'] and query.get('kind') == ['step'] and query.get('done') == ['true']:
                    return text
            return None
        checked_board = wait(checked_step, 'explicit step completion on native board')
        wait(lambda: not journal.exists(), 'changed native board writes settled')
        for title in expected_titles:
            assert checked_board.count(title) == original_board.count(title), 'live plan refresh duplicated hierarchy: '+title
        assert set(registry(runtime)['dispatch']['workers']) == held_workers, 'paused/held board synchronization launched work'
        assert imported()['plan_revision'] == execution_revision, 'presentation refresh rebound managed execution and its proof'
        result['live_board'] = {'path': board_path, 'source_revision': step_revision,
                                'execution_revision': execution_revision, 'journal_settled': True,
                                'progress_only_unchanged': True, 'explicit_step_checked': True,
                                'no_duplicate_hierarchy': True}
        checkpoint('live-plan-board-explicit-progress')

        begin(60)
        ui.command(product.controller, 'project_menu')  # Exactly one project.
        ui.choose('Conversation desk', "START this project's held work")
        started = wait(lambda: (row if (row := project_named('Conversation desk')) and row['started'] else None),
                       'explicit project START persisted')
        released = wait(lambda: (row if (row := imported()) and not row.get('held') else None),
                        'START releases selected source hold')
        assert started['associations'][attached['conversation_id']]['pane_binding'] == attached['pane_binding']
        result['started_project'], result['released_source'] = started, released
        checkpoint('conversation-explicit-start')

        begin(60)
        ui.command(product.controller, 'new_conversation')
        ui.choose('Existing orchestrated project or New', 'New project…')
        project_form = ui.form_pane('New project name')
        ui.edit_field(project_form, 'New project name', 'Separate discussion 𝔸')
        separate_name = 'Separate discussion 𝔸 — edited'
        ui.edit_field(project_form, 'New project name', separate_name)
        ui.mouse_click(project_form, 'Add project')
        separate_picker = ui.agent_picker('Choose an agent')
        ui('click', pane=separate_picker, label='Close')
        wait(lambda: all(pane['pane'] != separate_picker for pane in ui('panes')),
             'closed agent picker is removed before a plugin reload')
        separate = wait(lambda: project_named(separate_name), 'edited Unicode project name persisted')
        assert separate['started'] is False and separate['orch_project_id'] != parent_id
        assert separate['logical_session_id'] == parent['logical_session_id']
        assert not any(row['orch_project_id'] == separate['orch_project_id']
                       for row in registry(runtime)['dispatch']['workers'].values())
        result['separate_project'] = separate
        checkpoint('conversation-separate-project')

        begin(90)
        work_package = root/'plugins/tern/WORK'
        result['work_install'] = runtime.command('plugin', 'install', work_package)
        glitch_fixture = runtime.root/'glitch-work-fixture 𝔸'
        (glitch_fixture/'workspaces/native-walk').mkdir(parents=True)
        (glitch_fixture/'plans').mkdir()
        (glitch_fixture/'workspaces/registry.json').write_text(json.dumps({
            'workspaces': {'native-walk': {'status': 'active', 'path': 'native-walk'}}}))
        work_plan = glitch_fixture/'plans/native-work.md'
        work_plan.write_text('# Feature: Native WORK plan\n\n## Build choices\n'
                             'home: workspace:native-walk\n\n'
                             '### C1 — Work context\n#### Task W1 — Read supplied facts\n'
                             '**INDEPENDENT**\nDiscuss supplied facts only. Do not change files.\n')
        (glitch_fixture/'plans/retired-archive.md').write_text('# Feature: Archived WORK plan\n')
        ui('click', pane=product.controller, label='Settings')
        ui.command(product.controller, 'settings')
        instance_form = ui.form_pane('Orchestration settings')
        ui.click_match(instance_form, 'Glitch Integration')
        ui.switch_field(instance_form, 'Enable Glitch integration', True)
        ui.switch_field(instance_form, 'Enable Work On', True)
        session_id = parent['logical_session_id']
        ui('click', pane=instance_form, label='SAVE FOR THIS ORCHESTRATION INSTANCE ONLY')
        wait(lambda: registry(runtime)['dispatch']['policies'][session_id]['glitch_integration'] is True,
             'Glitch-enabled instance settings saved')
        wait(lambda: all(pane['pane'] != instance_form for pane in ui('panes')),
             'acknowledged instance save closes its editor')
        ui('click', pane=product.controller, label='Back to work')
        def continued_worker():
            dispatch = registry(runtime)['dispatch']
            current = dispatch['workers'][worker['worker_id']]
            origin = dispatch['command_cursors'][session_id]['origin']
            binding = current.get('control_pane_binding') or {}
            if (current['phase'] != 'accepted' or current['worker_generation'] != worker['worker_generation']
                    or current['mailbox_handle'] != worker['mailbox_handle']
                    or current.get('continuation_required') is not False
                    or current.get('control_origin') != origin
                    or binding.get('pane_id') != worker['pane_binding']['pane_id']):
                return None
            if any(binding.get(key) != origin.get(key) for key in ('window_epoch', 'window_key', 'native_session_id', 'window_host_id')):
                return None
            for action in dispatch['actions'].values():
                request = action.get('request') or action.get('draft') or {}
                if (action.get('worker_id') == worker['worker_id'] and request.get('op') == 'attach_worker'
                        and action['phase'] in ('ready', 'held_ready', 'claimed', 'uncertain')):
                    return None
            return current
        restored_worker = wait(continued_worker, 'positive retained worker attachment after reload')
        result['automatic_reconnection'] = {
            'worker_id': restored_worker['worker_id'], 'original_pane_preserved': True,
            'original_mailbox_preserved': True, 'control_origin': restored_worker['control_origin'],
            'control_pane_binding': restored_worker['control_pane_binding'], 'continuation_required': False}
        existing_workers = set(registry(runtime)['dispatch']['workers'])
        ui.command(product.controller, 'work-on')
        def work_pane():
            matches = [pane['pane'] for pane in ui('panes') if pane.get('block') == 'tern-work.panel']
            assert len(matches) <= 1, 'WORK ON created duplicate selection panes'
            if not matches:
                return None
            context = ui.machine(matches[0], 'work.orch.context', 'orch-context')
            return matches[0] if context and context.get('mode') == 'orchestration' and context.get('phase') == 'choosing' else None
        work = wait(work_pane, 'native WORK orchestration selection')
        ui.mouse_click(work, 'Configure Glitch folder')
        ui.edit_field(work, 'Glitch folder on execution host', str(glitch_fixture))
        ui.mouse_click(work, 'Use Glitch folder')
        def work_choices():
            surface = ui('surface', pane=work)
            text = json.dumps(surface, ensure_ascii=False)
            return surface if 'Native WORK plan' in text and 'native-walk' in text else None
        choices = wait(work_choices, 'discovered active workspace and unarchived plan')
        assert 'Archived WORK plan' not in json.dumps(choices), 'WORK offered an archived plan'
        ui.mouse_click(work, 'Native WORK plan')
        ui.mouse_click(work, 'Use selected context')
        ui.choose('Add to which project?', 'New project — Native WORK plan')
        work_import = wait(lambda: next((item for item in registry(runtime)['dispatch']['plans'].values()
                           if item.get('path') == str(work_plan)), None), 'WORK-selected plan imported')
        work_parent = wait(lambda: project_named('Native WORK plan'), 'WORK plan parent created')
        assert work_import['held'] is True and work_parent['started'] is False
        work_config = read_json(runtime.config/'plugin-data/tern-work/config.json')
        assert work_config == {'glitch_root': str(glitch_fixture)}, 'WORK required or invented a standalone agent'
        wait(lambda: (ui.machine(work, 'work.orch.context', 'orch-context') or {}).get('outcome') == 'success',
             'WORK consumer-confirmed success acknowledgement')
        assert set(registry(runtime)['dispatch']['workers']) == existing_workers, 'WORK selection started an agent'
        result['work_on'] = {'plan': work_import, 'project': work_parent, 'root_config': work_config,
                              'consumer_confirmed': True, 'agent_started': False}
        checkpoint('work-on-native-root-and-plan')

        if provider:
            observations = {}
            agents = {str(agent['pane']): agent for agent in ui('agents')}
            for record_id, saved_worker in (('c2-release', orchestrator), ('c2-builder', worker)):
                native = agents[saved_worker['pane_binding']['pane_id']]
                model = 'openai-codex/gpt-6-astra'
                session_dir = runtime.root/'provider-sessions'/record_id
                argv = shlex.split(native['command'])
                assert argv.count('--model') == 1 and argv[argv.index('--model')+1] == model
                assert argv.count('--session-dir') == 1 and Path(argv[argv.index('--session-dir')+1]) == session_dir
                observations[record_id] = {'native_agent': native,
                    'provider_identity': provider_session_identity(session_dir, model, saved_worker)}
            result['provider_conversation_proof'] = observations
        else:
            result['deterministic_transport_proof'] = {
                row['record_id']: {'worker': row, 'launch': read_json(product.control/row['mailbox_handle']/'launched.json'),
                                   'observations': worker_observations(product, row['mailbox_handle'])}
                for row in (worker,)}
            assert all(proof['launch'] for proof in result['deterministic_transport_proof'].values())
        result['checks'].extend([
            'missing SPAWN setup blocks orchestration creation before naming',
            'first unchanged default save changes Define to Edit without creating a session or altering policy',
            'live native plan board mirrors actual hierarchy and explicit steps while held, without Progress-prose rewrites',
            'Unicode pane fields preserve replacement edits and project isolation',
            'WORK ON configures a clean root and imports an unarchived plan without a standalone agent or agent start',
            'real local SPAWN setup and automatic conversation-first orchestration creation',
            'compact picker selected saved records with actual ACCEPTED evidence',
            'host-verified checkout and landing target saved through the native project menu without START',
            'named project parent and exact provider/account/native-title child in another tab',
            'passive active attachment and ACTIVE display do not START imported held work',
            'explicit START releases selected source; separate discussion remains unstarted',
            'zero SPAWN/USAGE transport panes at every native capture boundary'])
        if provider:
            result['checks'].append('actual Native OMP orchestrator adjacent to its panel; both conversations have exact provider/model/startup-binding evidence')
        else:
            result['checks'].append('verified terminal records correctly excluded from coordinator picker; visible cancellation launches no coordinator')
        ui.operation_deadline = None
        hold_started = True
        product.hold()
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = f'{type(error).__name__}: {error}'
        if hasattr(product, 'ui'):
            product.ui.operation_deadline = None
            result['failure_diagnostics'] = window_diagnostics(runtime, 'conversation-journey-failure')
            try:
                result['failure_context'] = product.ui('context')
                result['failure_panes'] = product.ui('panes')
                result['failure_forms'] = []
                for pane in result['failure_panes']:
                    if pane.get('block') != 'orchplus.form':
                        continue
                    form = {'pane': pane['pane']}
                    for label, options in (
                        ('receipt', {}),
                        ('product_caps', {'nodes': 4, 'depth': 2, 'max_chars': 262144}),
                    ):
                        try:
                            form[label] = product.ui('surface', pane=pane['pane'],
                                                     root='main.form-result', **options)
                        except Exception as diagnostic_error:
                            form[label+'_error'] = str(diagnostic_error)
                    result['failure_forms'].append(form)
            except Exception as diagnostic_error:
                result['failure_scope_error'] = str(diagnostic_error)
            if not hold_started:
                try:
                    product.hold()
                except Exception as hold_error:
                    result['capture_hold_error'] = f'{type(hold_error).__name__}: {hold_error}'
    finally:
        product.close()
    return result


def product_project_start(base, root, evidence, processes, lib, args):
    """Offline owner journey using exact packages and real terminal mailbox helpers."""
    unavailable = prerequisites()
    if unavailable:
        return unavailable
    assert not args.provider_agent_dir and not args.provider_coordinator and not args.provider_readiness, \
        'project-start-fixture never uses provider credentials or provider/native-OMP qualification'
    product = Product(base, root, evidence, processes, lib, 'project-start-fixture', args,
                      instrumented=False)
    result, runtime = product.result, product.runtime
    result.update(
        qualification_scope='owner UI and physical helper typed START transport using deterministic local-terminal coordinator; NOT provider/native-OMP qualification',
        unverified_matrix=['failed-publication hold is not fault-injected by this exact-package journey; run the separate lifecycle publication-failure regression'])
    try:
        product.start(installed=True)
        product.open_spawn()
        coordinator_record = product.create_record('start-coordinator', 'OMP', one_action=True)
        product.create_record('start-child', 'Codex', one_action=True)
        assert coordinator_record['backend'] == 'local-terminal'
        assert {'coordinator-control-v1', 'project-start-v1'} <= set(coordinator_record['mailbox']['capabilities'])
        product.initialize_orch()
        product.configure_orch('review_disabled', preferred_worker='start-child', release_manager='start-coordinator',
                               report_polling='00:01')
        assert registry(runtime)['installation_defaults']['policy']['poll_ms'] == 1000
        result['qualification_polling'] = 'One-second polling set through the public settings form in this disposable profile only; normal default timing is not qualified.'
        product.claim()
        product.configure_repository(product.repository)
        ui = product.ui
        ui.operation_deadline = time.monotonic()+180

        def capture(label):
            product.capture(label)
            assert 'shot' in result['captures'][label], 'native capture failed at '+label

        project = product.current_project()
        project_id, sid = project['orch_project_id'], project['logical_session_id']
        assert registry(runtime)['dispatch']['policies'][sid]['preferred_worker_record'] == 'start-child'
        ui.command(product.controller, 'start_orchestrator')
        project_choice = ui.form_pane('Choose a project')
        ui.mouse_click(project_choice, project['name'])
        ui.pick_agent('Choose your orchestrator', product.record_label('start-coordinator'))

        def activated():
            rows = [row for row in registry(runtime)['dispatch']['workers'].values()
                    if row['record_id'] == 'start-coordinator' and row['logical_session_id'] == sid]
            assert len(rows) <= 1, 'one selection created duplicate terminal coordinators'
            if rows and rows[0].get('mailbox_handle'):
                worker_observations(product, rows[0]['mailbox_handle'])
            return rows[0] if (rows and rows[0]['phase'] == 'accepted'
                               and rows[0].get('activation', {}).get('acknowledged')
                               and rows[0].get('pane_binding')) else None

        # Use the existing coordinator qualification budget: the public startup
        # handshake itself allows 120 seconds after the native pane is bound.
        coordinator = lib.wait_for(activated, 'terminal coordinator physical acceptance and activation', ui.remaining(180))
        handle = coordinator['mailbox_handle']
        result['coordinator_native_pane'] = [
            pane for pane in ui('panes') if pane['pane'] == int(coordinator['pane_binding']['pane_id'])]
        worker_command(product, handle, 'pause-control')
        # The real producer waits up to 120 seconds for its durable report receipt.
        # This is not a native mouse/callback operation.
        ui.operation_deadline = time.monotonic()+120
        plan_file = runtime.root/'typed-start-approved-plan.md'
        plan_file.write_text('# Feature: Typed START source approval\n\n'
                             '### Checkpoint 1 — Inspect supplied evidence\n'
                             '#### Task A1 — Read only the disposable qualification facts\n'
                             '**INDEPENDENT**\n'
                             'Read only this supplied fixture text. Do not modify files, launch children, merge or deploy.\n'
                             '##### Steps\n'
                             '- [ ] Read the supplied qualification facts.\n')
        plan_revision = hashlib.sha256(plan_file.read_bytes()).hexdigest()
        proposal_id = 'typed-start-owned-source-proposal'
        proposal = {'proposal_id': proposal_id, 'kind': 'add_source', 'orch_project_id': project_id,
                    'source': {'kind': 'plan_file', 'path': str(plan_file), 'revision': plan_revision}}
        worker_command(product, handle, 'propose-source', proposal)

        def proposed():
            rows = [gate for gate in registry(runtime)['dispatch']['gates'].values()
                    if gate.get('kind') == 'coordinator_proposal'
                    and gate.get('worker_id') == coordinator['worker_id']
                    and json.loads(gate['proposal'])['payload'].get('proposal_id') == proposal_id]
            assert len(rows) <= 1, 'physical helper duplicated proposal'
            return rows[0] if rows and rows[0]['phase'] == 'pending' else None

        gate = lib.wait_for(proposed, 'physical proposal reaches owner decision surface', ui.remaining(40))
        reported_proposal = json.loads(gate['proposal'])
        assert reported_proposal['kind'] == 'COORDINATOR_PROPOSAL'
        assert reported_proposal['payload'] == dict(
            proposal, owner_id=coordinator['coordinator_owner_id'],
            owner_generation=coordinator['coordinator_generation'],
            activation_token=coordinator['activation']['activation_token'])
        ui.operation_deadline = time.monotonic()+40
        capture('typed-start-proposal-awaiting-owner')
        answer_owner_gate(product, gate)

        def held_source():
            state = registry(runtime)
            rows = [plan for plan in state['dispatch'].get('plans', {}).values()
                    if plan.get('path') == str(plan_file) and plan['orch_project_id'] == project_id]
            assert len(rows) <= 1, 'one source approval imported the plan twice'
            assert not [worker for worker in state['dispatch']['workers'].values()
                        if worker['record_id'] == 'start-child' and worker['orch_project_id'] == project_id], \
                'source approval created child work before START claim'
            if not rows:
                return None
            plan = rows[0]
            assert plan['plan_revision'] == plan_revision, 'actual host parser observed a different source revision'
            assert len(plan['checkpoints']) == 1 and len(plan['checkpoints'][0]['tasks']) == 1
            task = plan['checkpoints'][0]['tasks'][0]
            assert task['id'] == 'A1' and not task.get('work_id') and not task.get('worker_id')
            assert task['state'] == 'queued_plan' and task['independent'] is True
            return plan if plan.get('held') is True else None

        held_plan = lib.wait_for(held_source, 'approved add_source parsed and imported as one held plan', ui.remaining(40))
        plan_id = held_plan['plan_id']
        assert not registry(runtime)['dispatch']['projects'][project_id]['started']
        result['source_proposal_evidence'] = {
            'gate_id': gate['id'], 'proposal_kind': reported_proposal['payload']['kind'],
            'source_path': str(plan_file), 'source_sha256': plan_revision,
            'observed_parser_revision': held_plan['plan_revision'], 'plan_id': plan_id,
            'checkpoint_count': len(held_plan['checkpoints']), 'task_id': held_plan['checkpoints'][0]['tasks'][0]['id'],
            'preferred_worker_record': registry(runtime)['dispatch']['policies'][sid]['preferred_worker_record']}
        # Include the asynchronous publication/observation round trip. Native
        # callbacks and the product's own effect deadline remain unchanged.
        ui.operation_deadline = time.monotonic()+120
        capture('typed-start-source-approved-held-no-child')
        ui.command(product.controller, 'project_menu')
        ui.choose(project['name'], "START this project's held work")
        if registry(runtime)['dispatch']['projects'][project_id].get('checks_pending'):
            ui.choose('Review declared checks for '+project['name'], 'START this project with these checks')

        def issued():
            current = registry(runtime)['dispatch']['projects'][project_id]
            start = current.get('start')
            if start and start.get('failure'):
                raise AssertionError('typed START publication failed: '+json.dumps(start['failure']))
            return start if start and start.get('published') else None

        start = lib.wait_for(issued, 'one immutable project_start physically published', ui.remaining(120))
        exact_bytes = start['bytes']
        snapshot = json.loads(json.dumps(start['snapshot']))
        assert set(snapshot['plans']) == {plan_id} and not snapshot['workers'], 'START did not capture exactly the approved held plan'
        reply = json.loads(exact_bytes)
        assert reply['kind'] == 'project_start'
        assert set(reply['payload']) == {'owner_id', 'owner_generation', 'activation_token',
                                       'orch_project_id', 'project_revision', 'decision_context'}
        current = registry(runtime)['dispatch']['projects'][project_id]
        assert not current['started'] and not start.get('claim'), 'publication alone released work'
        assert held_source()['plan_id'] == plan_id
        capture('typed-start-published-still-held')
        result['issued_start'] = {key: start[key] for key in
                                  ('start_id', 'project_revision', 'message_id', 'reply_seq', 'action_id', 'action_revision')}
        result['issued_start']['bytes_sha256'] = hashlib.sha256(exact_bytes.encode()).hexdigest()
        result['issued_start']['payload_keys'] = sorted(reply['payload'])
        result['issued_start']['snapshot_sha256'] = hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest()

        def reload_and_observe():
            ui.operation_deadline = time.monotonic()+120
            previous = registry(runtime)
            old_origin = ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')['command_cursor']['origin']
            target_panes = {int(worker['pane_binding']['pane_id']) for worker in previous['dispatch']['workers'].values()
                            if worker.get('pane_binding')}
            before_native = [pane for pane in ui('panes') if pane['pane'] in target_panes]
            previous_epochs = {worker_id: worker.get('workflow', {}).get('started', {}).get('epoch')
                               for worker_id, worker in previous['dispatch']['workers'].items()
                               if worker['phase'] == 'accepted'}
            runtime.command('plugin', 'reload', 'orchplus', '--json')

            def post_reload_ready():
                source = registry(runtime)
                for worker_id, old_epoch in previous_epochs.items():
                    worker = source['dispatch']['workers'][worker_id]
                    started = worker.get('workflow', {}).get('started', {})
                    if worker['phase'] == 'accepted' and (not isinstance(started.get('epoch'), str)
                                                         or started['epoch'] == old_epoch):
                        return None
                scope = ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
                if (scope and scope.get('authority_namespace') == source['authority_namespace']
                        and scope.get('authority_revision') == source['revision']
                        and registry(runtime)['revision'] == source['revision']):
                    return {'source_revision': source['revision'], 'previous_worker_start_epochs': previous_epochs}
                return None

            preflight = lib.wait_for(post_reload_ready, 'exact post-reload host epoch and native surface', ui.remaining(40))
            # Active-looking persisted controller state is not a new-incarnation
            # origin. Exercise the ordinary visible continuation and its attestation.
            ui('focus', pane=product.controller)
            ui('action', action='plugin.orchplus.continue_controller')
            ui.choose('Continue controller ', 'I independently verified previous ORCH+/SPAWN executors stopped or retired')
            after_native = ui('panes')
            result.setdefault('reload_native_targets', []).append({
                'before': before_native, 'after': [pane for pane in after_native if pane['pane'] in target_panes]})
            result.setdefault('explicit_continuations', []).append({
                'route': 'public Continue controller palette action and visible confirmation',
                'preflight': preflight, 'context': ui('context')})

            def restored():
                scope = ui.machine(product.controller, 'orchplus.dispatch', 'dispatch-state')
                current = registry(runtime)['dispatch']['projects'][project_id]
                retained = current.get('start')
                assert retained and retained['bytes'] == exact_bytes, 'reload replaced the immutable START grant'
                assert retained['start_id'] == start['start_id'] and retained['reply_seq'] == start['reply_seq']
                assert retained['snapshot'] == snapshot, 'reload changed the original owner-approved membership snapshot'
                fresh_origin = ((scope or {}).get('command_cursor') or {}).get('origin') or {}
                same_owner = all(fresh_origin.get(key) == old_origin.get(key) for key in ('owner_id', 'owner_generation'))
                continued = same_owner and fresh_origin.get('window_epoch') != old_origin.get('window_epoch')
                workers_now = registry(runtime)['dispatch']['workers']
                return current if (scope and scope.get('controller_phase') == 'active' and continued
                                   and all(not workers_now[worker_id].get('continuation_required')
                                           for worker_id in previous_epochs)) else None
            return lib.wait_for(restored, 'same grant and explicitly continued owner after native reload', ui.remaining(120))

        restored = reload_and_observe()
        assert not restored['started'] and not restored['start'].get('claim')
        assert held_source()['plan_id'] == plan_id, 'reload released the unclaimed held plan'
        capture('typed-start-reloaded-before-claim')
        source_context = ui('context')
        other_session = ui('session_create', name='START background independence fixture', cwd=str(product.repository))
        assert other_session['id'] != source_context['session']['id'], 'background fixture did not create a second native session'

        def selection():
            context = ui('context')
            return {'window': context['window'], 'host_id': context['host']['id'],
                    'session_id': context['session']['id'], 'focused': context.get('focused'),
                    'focus_revision': context['focus_revision']}

        lib.idle(.1)  # Settle the explicit session-create focus event before the no-focus-change baseline.
        background_context = selection()
        assert background_context['session_id'] == other_session['id']
        assert background_context['window'] == source_context['window']
        result['background_selection'] = {'source_session_id': source_context['session']['id'],
                                          'selected_before_claim': background_context}

        def background_unchanged():
            if background_context is not None:
                assert selection() == background_context, 'owned background settlement changed selected session, focus, host or window'

        capture('typed-start-second-session-selected-before-claim')
        ui.operation_deadline = time.monotonic()+60
        worker_command(product, handle, 'resume-control')
        background_unchanged()

        def released():
            background_unchanged()
            current = registry(runtime)['dispatch']['projects'][project_id]
            current_plan = registry(runtime)['dispatch']['plans'][plan_id]
            worker_observations(product, handle)
            assert current_plan['plan_revision'] == plan_revision
            return (current, current_plan) if (current.get('started') and current.get('start', {}).get('claim')
                                              and not current_plan.get('held')) else None

        current, released_plan = lib.wait_for(released, 'actual correlated claim accepted before exact held plan release', ui.remaining(60))
        claim = json.loads(current['start']['claim'])
        assert claim['kind'] == 'PROJECT_START_CLAIM' and claim['payload'] == reply['payload']
        assert claim['action_id'] == reply['action_id'] and claim['action_revision'] == reply['action_revision']
        assert claim['worker_id'] == coordinator['worker_id']
        ui.operation_deadline = time.monotonic()+40

        def physical_completion():
            background_unchanged()
            observation = worker_observations(product, handle)
            reports = [event for event in observation['events'] if event['kind'] == 'report'
                       and event['report']['kind'] == 'PROJECT_START_CLAIM']
            resolutions = [event for event in observation['events'] if event['kind'] == 'resolved'
                           and event.get('message_id') == reply['message_id']]
            assert len(reports) <= 1 and len(resolutions) <= 1, 'START was executed or reported twice'
            return observation if reports and resolutions else None

        observations = lib.wait_for(physical_completion, 'physical claim acceptance receipt and helper resolution', ui.remaining(40))
        report, = [event for event in observations['events'] if event['kind'] == 'report'
                   and event['report']['kind'] == 'PROJECT_START_CLAIM']
        assert report['seq'] == claim['seq'] and report['ack']['disposition'] == 'accepted'
        consumed, = [event for event in observations['events'] if event['kind'] == 'reply'
                     and event['reply']['message_id'] == reply['message_id']]
        assert consumed['reply'] == reply and consumed['sha256'] == hashlib.sha256(exact_bytes.encode()).hexdigest()
        calls = observations['helper_calls']
        claimed, = [call for call in calls if call['mode'] == 'claim' and call['message'] == reply['message_id']]
        resolved, = [call for call in calls if call['mode'] == 'resolve' and call['message'] == reply['message_id']]
        assert claimed['returncode'] == resolved['returncode'] == 0
        assert claimed['finished_ns'] <= resolved['started_ns']
        ui.operation_deadline = time.monotonic()+40

        def background_launch_held():
            background_unchanged()
            state = registry(runtime)
            plans = [plan for plan in state['dispatch']['plans'].values()
                     if plan.get('path') == str(plan_file) and plan['orch_project_id'] == project_id]
            assert len(plans) == 1 and plans[0]['plan_id'] == plan_id and not plans[0].get('held')
            task = plans[0]['checkpoints'][0]['tasks'][0]
            if not task.get('worker_id'):
                return None
            worker = state['dispatch']['workers'][task['worker_id']]
            assert worker['record_id'] == 'start-child' and worker['work_id'] == task['work_id']
            assert worker['source'] == {'kind': 'plan', 'ref': str(plan_file)+'#A1', 'revision': plan_revision}
            assert worker['placement'] == 'tab', 'this fixture observes the configured tab route, not a split/native workaround'
            assert not worker.get('pane_binding'), 'inactive-session tab launch unexpectedly issued'
            assert not any((read_json(path) or {}).get('record_id') == 'start-child'
                           for path in product.control.glob('*/launched.json')), 'child launched while its source session was not selected'
            rows = [(action_id, action) for action_id, action in state['dispatch']['actions'].items()
                    if action.get('worker_id') == worker['worker_id'] and action['request']['op'] == 'launch']
            assert len(rows) <= 1, 'host release produced duplicate child launch actions'
            if not rows:
                return None
            action_id, action = rows[0]
            assert action['phase'] == 'ready' and not action.get('claim') and not action.get('request_bytes'), \
                'inactive-session new-tab creation must remain unclaimed and unissued'
            return {'action_id': action_id, 'request_id': action['request']['request_id'],
                    'worker_id': worker['worker_id'], 'phase': action['phase'], 'selected_context': selection()}

        pending_launch = lib.wait_for(background_launch_held, 'background claim accepted while configured tab launch stays unissued', ui.remaining(40))
        child = registry(runtime)['dispatch']['workers'][pending_launch['worker_id']]
        lib.idle(1)
        assert background_launch_held() == pending_launch, 'background scheduling replaced or issued the original child launch'
        result['background_selection']['after_accepted_receipt_and_release'] = selection()
        result['background_selection']['unissued_tab_launch'] = pending_launch
        capture('typed-start-background-claimed-child-tab-unissued')
        background_unchanged()
        background_context = None
        # Require both sides' acceptance and the real process proof before the
        # second reload; use the same bounded startup qualification as above.
        ui.operation_deadline = time.monotonic()+180
        selected_source = ui('session_switch', session=source_context['session']['id'])
        assert selected_source['id'] == source_context['session']['id']
        ui('focus', pane=product.controller)

        def accepted_child():
            worker = registry(runtime)['dispatch']['workers'][child['worker_id']]
            if worker.get('mailbox_handle'):
                worker_observations(product, worker['mailbox_handle'])
            peer = (read_json(runtime.config/'plugin-data/spawn/kv.json') or {}).get('dispatch-v1', {})
            launch_key = sid+'/'+pending_launch['request_id']
            pending = peer.get('requests', {}).get(launch_key)
            retained = peer.get('workers', {}).get(launch_key)
            phase = pending.get('body', {}).get('status') if pending else (retained or {}).get('phase')
            proof = (pending or retained or {}).get('terminal_process')
            if worker['phase'] == 'accepted' and worker.get('pane_binding') and phase == 'accepted' and proof:
                result['child_acceptance'] = {'orch_phase': worker['phase'], 'spawn_phase': phase,
                                               'terminal_process_identity_recorded': bool(proof)}
                return worker
            return None

        accepted_child_worker = lib.wait_for(accepted_child, 'child accepted by ORCH and SPAWN with retained native process proof', ui.remaining(180))
        assert accepted_child_worker['launch_action_id'] == pending_launch['action_id'], 'returning to source replaced the original child launch'
        after = reload_and_observe()
        assert after['started'] and after['start']['claim'] == current['start']['claim']
        lib.idle(1)
        assert physical_completion(), 'reload duplicated or lost physical START execution'
        rows = [row for row in registry(runtime)['dispatch']['workers'].values()
                if row['record_id'] == 'start-child' and row['orch_project_id'] == project_id]
        assert len(rows) == 1 and rows[0]['worker_id'] == child['worker_id']
        launch_log = product.control/'native-launches.jsonl'
        actual_child_launches = [row for row in
                                (json.loads(line) for line in launch_log.read_text().splitlines() if line)
                                if row['record_id'] == 'start-child']
        assert len(actual_child_launches) == 1, 'the original child was physically invoked more than once'
        assert actual_child_launches[0]['mailbox_handle'] == accepted_child_worker['mailbox_handle']
        projected = ui.machine(product.controller, 'orchplus.projects', 'project-index')['projects'][project_id]
        assert projected['started'] and projected['start']['state'] == 'claimed'
        assert 'payload' not in projected['start'] and 'activation_token' not in projected['start']
        result['claimed_project_projection'] = projected['start']
        capture('typed-start-claimed-host-release-after-reload')
        result['claim_evidence'] = {
            'report_seq': claim['seq'], 'action_id': claim['action_id'], 'action_revision': claim['action_revision'],
            'payload_matches_exact_reply': True, 'accepted_receipt': report['ack'],
            'worker_observations': str(product.control/handle/'observations.json'),
            'physical_producer_journal': str(Path(coordinator_record['mailbox']['permitted_root'])/handle/'producer/journal.json'),
            'helper_claim': claimed, 'helper_resolve': resolved, 'released_plan_id': released_plan['plan_id'],
            'released_worker_id': child['worker_id'],
            'released_child_observations': str(product.control/accepted_child_worker['mailbox_handle']/'observations.json'),
            'physical_child_launch': actual_child_launches[0], 'physical_launch_log': str(launch_log)}
        result['checks'] = [
            'physical COORDINATOR_PROPOSAL add_source plan_file and owner approval import one parser-observed held plan without creating child work',
            'one owner START physically publishes an immutable six-field typed reply without releasing work',
            'native ORCH reload preserves the same pending grant and held membership',
            'real shipped terminal helper consumes, locally claims, reports exact action-correlated PROJECT_START_CLAIM and drains its accepted receipt',
            'physical claim, accepted receipt and host release settle while another same-window session remains selected with unchanged focus',
            'configured tab child stays ready/unclaimed/unissued in background; explicit source selection launches that original action once',
            'public Continue controller after each reload retains the same grant, plan snapshot and resulting child without fabricated origin']
        result['status'] = 'passed'
    except Exception as error:
        result.update(status='failed', error=f'{type(error).__name__}: {error}')
        result['failure_traceback'] = traceback.format_exc()
        if hasattr(product, 'ui'):
            product.ui.operation_deadline = None
            result['failure_diagnostics'] = window_diagnostics(runtime, 'project-start-fixture-failure')
    finally:
        product.close()
    return result
