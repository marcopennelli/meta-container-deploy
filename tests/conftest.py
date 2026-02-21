"""
Test fixtures and BitBake datastore mock for meta-container-deploy bbclass testing.

The bbclass files contain Python functions that depend on BitBake's datastore (d)
and bb module. This module provides mocks that allow testing the generation logic
without a full BitBake environment.
"""

import os
import re
import sys
import types
import tempfile

import pytest


class MockDataStore:
    """Mock BitBake DataStore that supports getVar/setVar."""

    def __init__(self):
        self._vars = {}

    def getVar(self, name, expand=True):
        return self._vars.get(name, None)

    def setVar(self, name, value):
        self._vars[name] = value

    def appendVar(self, name, value):
        current = self._vars.get(name, '')
        self._vars[name] = current + value

    def delVar(self, name):
        self._vars.pop(name, None)


class MockBB:
    """Mock BitBake bb module."""

    def __init__(self):
        self.notes = []
        self.warnings = []
        self.fatals = []

    def note(self, msg):
        self.notes.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    def fatal(self, msg):
        self.fatals.append(msg)
        raise BBFatalError(msg)


class BBFatalError(Exception):
    """Raised when bb.fatal() is called."""
    pass


def extract_python_functions(bbclass_path):
    """Extract Python function bodies from a bbclass file.

    Handles two types:
    1. Standard Python defs: 'def func_name(...):'
    2. BitBake Python tasks: 'python task_name() {'
    """
    with open(bbclass_path, 'r') as f:
        content = f.read()

    functions = {}

    # Extract standard Python defs (they're at module level in bbclass files)
    # These are regular Python function definitions
    lines = content.split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        # Match 'def func_name(...):'
        match = re.match(r'^def\s+(\w+)\s*\(', line)
        if match:
            func_name = match.group(1)
            func_lines = [line]
            i += 1
            while i < len(lines):
                # Continue until we hit a non-indented, non-empty line
                if lines[i] and not lines[i][0].isspace() and not lines[i].startswith('#'):
                    break
                func_lines.append(lines[i])
                i += 1
            functions[func_name] = '\n'.join(func_lines)
            continue

        # Match 'python task_name() {'
        match = re.match(r'^python\s+(\w+)\s*\(\)\s*\{', line)
        if match:
            func_name = match.group(1)
            task_lines = []
            i += 1
            brace_depth = 1
            while i < len(lines) and brace_depth > 0:
                # Count braces in the line (but not in strings)
                for ch in lines[i]:
                    if ch == '{':
                        brace_depth += 1
                    elif ch == '}':
                        brace_depth -= 1
                        if brace_depth == 0:
                            break
                if brace_depth > 0:
                    task_lines.append(lines[i])
                i += 1
            # Wrap as a function that takes d as parameter
            body = '\n'.join(task_lines)
            functions[func_name] = f"def {func_name}(d, bb):\n" + \
                '\n'.join('    ' + l if l.strip() else '' for l in task_lines)
            continue

        i += 1

    return functions


def load_bbclass(bbclass_path, mock_bb=None):
    """Load a bbclass file and return a namespace with its Python functions.

    Returns a module-like namespace where all functions are available.
    """
    if mock_bb is None:
        mock_bb = MockBB()

    functions = extract_python_functions(bbclass_path)

    # Build a combined source with all standard defs first
    namespace = {
        'bb': mock_bb,
        'os': os,
        '__builtins__': __builtins__,
    }

    # First, compile and exec all standard Python defs (helpers)
    helper_source = []
    task_source = {}
    for name, source in functions.items():
        if source.startswith('def ') and not source.startswith(f'def {name}(d, bb)'):
            helper_source.append(source)
        else:
            task_source[name] = source

    if helper_source:
        combined = '\n\n'.join(helper_source)
        exec(compile(combined, bbclass_path, 'exec'), namespace)

    # Then compile task functions (they may reference helpers)
    for name, source in task_source.items():
        exec(compile(source, bbclass_path, 'exec'), namespace)

    return namespace


@pytest.fixture
def mock_bb():
    """Provide a fresh MockBB instance."""
    return MockBB()


@pytest.fixture
def datastore():
    """Provide a fresh MockDataStore instance."""
    return MockDataStore()


@pytest.fixture
def workdir():
    """Provide a temporary working directory."""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield tmpdir


@pytest.fixture
def classes_dir():
    """Return the path to the bbclass files."""
    return os.path.join(os.path.dirname(os.path.dirname(__file__)), 'classes')


def parse_quadlet(content):
    """Parse a Quadlet file into sections with their key-value pairs.

    Returns a dict like:
    {
        'Unit': {'Description': '...', 'After': ['...', '...']},
        'Container': {'Image': '...', 'PublishPort': ['8080:80']},
        'Service': {'Restart': 'always'},
        'Install': {'WantedBy': 'multi-user.target'},
    }

    Multi-valued keys are stored as lists.
    """
    sections = {}
    current_section = None

    for line in content.split('\n'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('[') and line.endswith(']'):
            current_section = line[1:-1]
            sections[current_section] = {}
            continue
        if current_section and '=' in line:
            key, value = line.split('=', 1)
            if key in sections[current_section]:
                existing = sections[current_section][key]
                if isinstance(existing, list):
                    existing.append(value)
                else:
                    sections[current_section][key] = [existing, value]
            else:
                sections[current_section][key] = value

    return sections
