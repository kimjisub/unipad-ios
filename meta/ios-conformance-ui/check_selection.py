"""Exact-title regression and device-free lazy-list ordering model (not UI proof)."""
import argparse
import pathlib
import zipfile


class LazyList:
    """Only the current screen's labels exist, as in a virtualized pack list.

    The guiding actions row follows the last card, so it is visible only on the
    last screen. Swipes whose index is in `lost` do not move the list, as the
    quick swipe in JIS-424 did not on iOS 26.3.
    """

    def __init__(self, screens, lost=()):
        self.screens = screens
        self.lost = set(lost)
        self.index = 0
        self.swipes = 0

    @property
    def titles(self):
        return self.screens[self.index]

    @property
    def count(self):
        return self.titles.count('Conformance')

    @property
    def end_visible(self):
        return self.index == len(self.screens) - 1

    def swipe_up(self):
        if self.swipes not in self.lost:
            self.index = min(self.index + 1, len(self.screens) - 1)
        self.swipes += 1


def original_order(listing):
    # e7192306 checks count before its single attempt to reveal the title.
    assert listing.count == 1, 'Original order: title count before scrolling'
    return listing.swipes


def unchanged_labels_order(listing):
    # e37e886 took one unchanged screen after a swipe as the end of the list.
    previous = None
    while True:
        if listing.count >= 2:
            raise AssertionError('Duplicate exact titles')
        if listing.swipes >= 40:
            raise AssertionError('Title missing: 40-swipe limit')
        if listing.count == 1:
            return listing.swipes
        if previous == listing.titles:
            raise AssertionError('Title missing: end of pack list')
        previous = listing.titles
        listing.swipe_up()


def search_order(listing):
    counts = []
    stalls = 0
    previous = None
    while True:
        count = listing.count
        counts.append(count)
        if count >= 2:
            raise AssertionError('Duplicate exact titles')
        if listing.swipes >= 40:
            raise AssertionError('Title missing: 40-swipe limit')
        if count == 1:
            assert listing.count == 1  # Selection-time recheck.
            return listing.swipes, counts, stalls
        if listing.end_visible:
            raise AssertionError('Title missing: end of pack list')
        if previous == listing.index:
            stalls += 1
        previous = listing.index
        listing.swipe_up()


def expect_failure(name, action, message):
    try:
        action()
    except AssertionError as error:
        assert message in str(error), f'{name}: unexpected failure {error}'
        print(f'PASS {name}: {error}')
    else:
        raise AssertionError(f'{name}: unexpectedly selected a title')


def check_model(overlay):
    screens = [['Pack A'], ['Pack B'], ['Conformance']]
    expect_failure('original order', lambda: original_order(LazyList(screens)), 'before scrolling')
    swipes, counts, stalls = search_order(LazyList(screens))
    assert (swipes, counts, stalls) == (2, [0, 0, 1], 0)
    print(f'PASS new order: swipes={swipes} counts={counts}')
    long_screens = [[f'Pack {i}'] for i in range(35)] + [['Conformance']]
    swipes, counts, _ = search_order(LazyList(long_screens))
    assert swipes == 35 and counts == [0] * 35 + [1]
    print(f'PASS long list: swipes={swipes} counts={counts}')
    edge_screens = [[f'Pack {i}'] for i in range(39)] + [['Conformance']]
    assert search_order(LazyList(edge_screens))[0] == 39
    print('PASS below swipe limit: swipes=39')
    expect_failure('title at swipe limit', lambda: search_order(
        LazyList([[f'Pack {i}'] for i in range(40)] + [['Conformance']])), '40-swipe limit')
    expect_failure('duplicate on first screen', lambda: search_order(
        LazyList([['Conformance', 'Conformance']])), 'Duplicate')
    expect_failure('duplicate after scrolling', lambda: search_order(
        LazyList([['Pack A'], ['Conformance', 'Conformance']])), 'Duplicate')
    expect_failure('missing title', lambda: search_order(
        LazyList([['Pack A'], ['Pack B']])), 'end of pack list')
    expect_failure('swipe limit', lambda: search_order(
        LazyList([[f'Pack {i}'] for i in range(42)] + [['Conformance']])), '40-swipe limit')

    # JIS-424: six shared packs plus the fixture, the first swipe lost.
    jis424 = [['QA - Control', 'Alan Walker - Faded', 'Playback Stop Fixture', 'Local Tone', 'OMFG - Hello'],
              ['Local Tone', 'OMFG - Hello', 'Local Tone', 'Conformance']]
    expect_failure('e37e886 order, lost swipe', lambda: unchanged_labels_order(
        LazyList(jis424, lost={0})), 'end of pack list')
    swipes, counts, stalls = search_order(LazyList(jis424, lost={0}))
    assert (swipes, counts, stalls) == (2, [0, 0, 1], 1)
    print(f'PASS lost swipe retried: swipes={swipes} counts={counts} stalls={stalls}')
    expect_failure('every swipe lost', lambda: search_order(
        LazyList(jis424, lost=range(40))), '40-swipe limit')

    # Narrow source guards tie the model's ordering to the overlay. They are
    # not an execution of XCTest, accessibility queries, or hittability.
    swift = overlay.read_text()
    start = swift.find('private func exactFixtureTitle(')
    assert start >= 0, 'Overlay still uses the original pre-scroll title assertion'
    search = swift[start:swift.index('func testSyntheticPackInputAutoplayAndExit', start)]
    assert 'if listEnd.isHittable' in search, 'Overlay takes one unmoved screen as the end of the list'
    assert search.index('if count >= 2') < search.index('if count == 1 && matches.firstMatch.isHittable')
    assert search.index('swipes >= 40') < search.index('if count == 1 && matches.firstMatch.isHittable')
    assert search.index('if count == 1 && matches.firstMatch.isHittable') < search.index('if listEnd.isHittable')
    assert search.index('if listEnd.isHittable') < search.index('scrollOneStep(list)\n')
    assert '"main.guide.download"' in search
    stall = search[search.index('if previousPosition == position'):search.index('scrollOneStep(list)\n')]
    assert 'XCTFail' not in stall, 'An unmoved list must be retried, not taken as the end'
    assert 'swipeUp()' not in search
    assert 'withVelocity: .slow, thenHoldForDuration:' in search
    assert 'CONFORMANCE title-search swipes=' in search
    assert 'XCTAssertEqual(matches.count, 1' in search
    assert 'XCTAssertTrue(matches.firstMatch.isHittable' in search
    assert 'guard let title = exactFixtureTitle(in: list) else { return }' in swift
    print('PASS overlay source ordering guards (device-free model only)')


p = argparse.ArgumentParser()
p.add_argument('pack', type=pathlib.Path)
p.add_argument('--legacy', action='store_true')
p.add_argument('--overlay', type=pathlib.Path, default=pathlib.Path(__file__).with_name('PlayPadLayoutTests.swift'))
a = p.parse_args()
with zipfile.ZipFile(a.pack) as z:
    info = z.read('info').decode()
title = next(line.split('=', 1)[1] for line in info.splitlines() if line.startswith('title='))
selected = ' - ' in title if a.legacy else title == 'Conformance'
assert selected, f'Legacy selector cannot select exact synthetic title {title!r}'
print(f'Exact title selector accepts {title!r}')
check_model(a.overlay)
