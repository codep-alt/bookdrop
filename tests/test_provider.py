"""Unit tests for bookdrop.koplugin/bookdrop_provider.lua (Internet Archive).

The provider is plain Lua against KOReader's LuaSocket/rapidjson C modules.
lupa runs the module with those modules stubbed and a canned HTTP route
table, exercising the real search/metadata parsing and acquisition logic.
"""

import json
from pathlib import Path

from lupa import LuaRuntime

SEARCH_DOCS = [
    {
        "identifier": "great_expectations",
        "title": "Great Expectations",
        "creator": "Charles Dickens",
        "description": "A novel.",
        "language": ["eng"],
        "date": "1861-01-01T00:00:00Z",
        "downloads": 123456,
        "subject": ["Fiction", "Classics"],
        "publisher": "Chapman & Hall",
        "format": ["EPUB", "PDF"],
        "isbn": "9780141439563",
    },
    {
        "identifier": "olivertwist",
        "title": "Oliver Twist",
        "creator": "Charles Dickens",
        "language": ["eng"],
        "date": "1838",
        "format": ["DjVu", "DjVuTXT"],
    },
]

SEARCH_RESPONSE = {
    "response": {
        "numFound": 2345,
        "start": 0,
        "docs": SEARCH_DOCS,
    }
}

METADATA_RESPONSE = {
    "metadata": {
        "title": "Great Expectations: The Complete Novel",
        "creator": "Charles Dickens",
        "description": "<p>A longer description.</p>",
        "language": ["English"],
        "date": "1861",
        "publisher": "Chapman & Hall",
        "isbn": "9780141439563",
        "subject": ["Fiction", "Classics"],
        "rights": "Public domain in the USA",
        "downloads": 123456,
        "access-restricted-item": False,
    },
    "files": [
        {"name": "great_expectations.epub", "size": 1048576, "md5": "abc123",
         "source": "original", "format": "EPUB", "private": False},
        {"name": "great_expectations.pdf", "size": 2097152,
         "source": "derivative", "format": "Text PDF", "private": False},
        {"name": "great_expectations_private.pdf", "size": 999,
         "source": "original", "format": "PDF", "private": True},
    ],
}

RESTRICTED_RESPONSE = {
    "metadata": {"access-restricted-item": True, "title": "Restricted"},
    "files": [],
}

ROUTES = [
    ("/advancedsearch.php", json.dumps(SEARCH_RESPONSE)),
    ("/metadata/great_expectations", json.dumps(METADATA_RESPONSE)),
    ("/metadata/restricted_item", json.dumps(RESTRICTED_RESPONSE)),
]

lua = LuaRuntime(unpack_returned_tuples=True)


def to_lua(value):
    """Recursively convert JSON (dict/list/str/int/float/bool) to Lua values.

    lupa's lua.table_from() only converts the top level, leaving nested
    Python objects as userdata that Lua cannot safely index or iterate.
    """
    if isinstance(value, dict):
        table = lua.table()
        for key, item in value.items():
            table[key] = to_lua(item)
        return table
    if isinstance(value, (list, tuple)):
        table = lua.table()
        for index, item in enumerate(value, start=1):
            table[index] = to_lua(item)
        return table
    return value


def python_json_decode(text):
    return to_lua(json.loads(text))


def python_http_request(arg):
    url = arg["url"]
    for marker, body in ROUTES:
        if marker in url:
            arg["sink"](body)
            return (True, 200, None, "OK")
    return (None, None, None, "no fixture for " + url)


lua.globals()["python_json_decode"] = python_json_decode
lua.globals()["python_http_request"] = python_http_request

lua.execute(
    r'''
    package.preload["socketutil"] = function()
        return { set_timeout = function() end, reset_timeout = function() end }
    end
    package.preload["socket.url"] = function()
        return { escape = function(value) return value end }
    end
    package.preload["ltn12"] = function()
        return { sink = { file = function() end } }
    end
    package.preload["rapidjson"] = function()
        return { decode = function(text) return python_json_decode(text) end }
    end
    package.preload["socket.http"] = function()
        return { request = function(arg) return python_http_request(arg) end }
    end
    '''
)

provider = lua.execute(Path("bookdrop.koplugin/bookdrop_provider.lua").read_text())
lua.globals()["provider"] = provider

lua.execute(
    r'''
    page = provider:search("dickens", 1, {})
    hydrated, hydrate_err = provider:hydrate({ provider_id = "great_expectations" })
    restricted, restricted_err = provider:hydrate({ provider_id = "restricted_item" })
    '''
)

page = lua.globals().page
books = page["books"]
assert len(books) == 2, f"expected 2 records, got {len(books)}"

first = books[1]
assert first["title"] == "Great Expectations"
assert first["author"] == "Charles Dickens"
assert first["id"] == "great_expectations"
assert first["provider_id"] == "great_expectations"
assert first["cover_url"].startswith("https://covers.openlibrary.org/")
assert first["year"] == "1861"
assert first["format"] == "EPUB"
assert first["available_formats"] == "EPUB · PDF"
assert first["content_type"] == "Book (fiction)"

second = books[2]
assert second["id"] == "olivertwist"
assert second["cover_url"] == "https://archive.org/services/img/olivertwist"

assert page["total"] == 2345
assert page["page"] == 1
assert page["has_next"] is True

hydrated = lua.globals().hydrated
restricted = lua.globals().restricted
restricted_err = lua.globals().restricted_err

assert hydrated is not None
assert hydrated["title"] == "Great Expectations: The Complete Novel"
assert hydrated["year"] == "1861"
acquisitions = hydrated["acquisitions"]
assert len(acquisitions) == 2, f"expected 2 public files, got {len(acquisitions)}"
assert acquisitions[1]["extension"] == "epub"
assert acquisitions[1]["format"] == "EPUB"
assert acquisitions[1]["url"] == (
    "https://archive.org/download/great_expectations/great_expectations.epub")
assert acquisitions[2]["extension"] == "pdf"
assert hydrated["format"] == "EPUB"
assert hydrated["size"] == "1.0 MB"

assert restricted is None
assert "restricted" in restricted_err.lower()

print(f"parsed {len(books)} catalog records with cover metadata")
print(f"hydrated {len(acquisitions)} public acquisitions; "
      f"restricted item rejected: {restricted is None}")
