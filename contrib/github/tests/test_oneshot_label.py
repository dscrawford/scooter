"""The one-shot label starts a conversation that cleans itself up; the normal label does not."""

import asyncio
from unittest.mock import AsyncMock, patch

import pytest

from scooter_contrib_github import webhooks_handler as gh


def _labeled(kind: str, label: str) -> dict:
    item = {"number": 42, "title": "[home-watch] 1 Main St", "body": "score this"}
    return {
        "action": "labeled",
        "label": {"name": label},
        kind: item,
        "sender": {"login": "home-watcher"},
        "repository": {"owner": {"login": "dscrawford"}, "name": "home-watcher"},
    }


@pytest.fixture
def create():
    create = AsyncMock()
    with patch.object(gh, "_background_create_conversation", new=create), \
         patch.object(gh.db, "store_conversation", new=AsyncMock()):
        yield create


@pytest.mark.parametrize("kind, handle", [("issue", "_handle_issue_event"), ("pull_request", "_handle_pr_event")])
@pytest.mark.parametrize("label, oneshot", [("scooter-oneshot", True), ("Scooter-Oneshot", True), ("scooter", False)])
async def test_label_picks_oneshot(create, kind, handle, label, oneshot):
    await getattr(gh, handle)(_labeled(kind, label))
    await asyncio.sleep(0)
    assert create.await_args.kwargs["oneshot"] is oneshot


async def test_oneshot_label_is_off_when_unset(create, trigger_policy):
    trigger_policy.oneshot_label_trigger = ""
    await gh._handle_issue_event(_labeled("issue", "scooter-oneshot"))
    await asyncio.sleep(0)
    assert not create.called


async def test_oneshot_reaches_create_conversation():
    created = AsyncMock(return_value={"conversation_id": "c1", "result": ""})
    with patch.object(gh, "create_conversation", new=created), \
         patch.object(gh, "resolve_owner", new=AsyncMock(return_value=None)), \
         patch.object(gh.db, "get_and_clear_pending_messages", new=AsyncMock(return_value=[])):
        await gh._background_create_conversation(
            res_type="issue", res_id="dscrawford/home-watcher#42", message="m",
            repo="dscrawford/home-watcher", conv_title="t", owner="dscrawford",
            repo_name="home-watcher", issue_number=42, oneshot=True,
        )
    assert created.await_args.kwargs["oneshot"] is True
