"""Exact-title regression and device-free lazy-list ordering model (not UI proof)."""
import argparse
import pathlib
import zipfile


class LazyList:
    """Only the current screen's labels exist, as in a virtualized pack list."""

    def __init__(self, screens):
        self.screens = screens
        self.index = 0
        self.swipes = 0

    @property
    def titles(self):
        return self.screens[self.index]

    @property
    def count(self):
        return self.titles.count('Conformance')

    def swipe_up(self):
        self.index = min(self.index + 1, len(self.screens) - 1)
        self.swipes += 1


def original_order(listing):
    # e7192306 checks count before its single attempt to reveal the title.
    assert listing.count == 1, 'Original order: title count before scrolling'
    return listing.swipes


def search_order(listing):
    counts = []
    previous = None
    while True:
        count = listing.count
        counts.append(count)
        if count >= 2:
            raise AssertionError('Duplicate exact titles')
        if count == 1:
            assert listing.count == 1  # Selection-time recheck.
            return listing.swipes, counts
        visible = listing.titles
        if previous == visible:
            raise AssertionError('Title missing: end of pack list')
        if listing.swipes >= 40:
            raise AssertionError('Title missing: 40-swipe limit')
        previous = visible
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
    swipes, counts = search_order(LazyList(screens))
    assert (swipes, counts) == (2, [0, 0, 1])
    print(f'PASS new order: swipes={swipes} counts={counts}')
    long_screens = [[f'Pack {i}'] for i in range(35)] + [['Conformance']]
    swipes, counts = search_order(LazyList(long_screens))
    assert swipes == 35 and counts == [0] * 35 + [1]
    print(f'PASS long list: swipes={swipes} counts={counts}')
    expect_failure('duplicate on first screen', lambda: search_order(
        LazyList([['Conformance', 'Conformance']])), 'Duplicate')
    expect_failure('duplicate after scrolling', lambda: search_order(
        LazyList([['Pack A'], ['Conformance', 'Conformance']])), 'Duplicate')
    expect_failure('missing title', lambda: search_order(
        LazyList([['Pack A'], ['Pack B']])), 'end of pack list')
    expect_failure('swipe limit', lambda: search_order(
        LazyList([[f'Pack {i}'] for i in range(42)] + [['Conformance']])), '40-swipe limit')

    # Narrow source guards tie the model's ordering to the overlay. They are
    # not an execution of XCTest, accessibility queries, or hittability.
    swift = overlay.read_text()
    start = swift.find('private func exactFixtureTitle(')
    assert start >= 0, 'Overlay still uses the original pre-scroll title assertion'
    search = swift[start:swift.index('func testSyntheticPackInputAutoplayAndExit', start)]
    assert search.index('if count >= 2') < search.index('if count == 1 && matches.firstMatch.isHittable')
    assert search.index('previousTitles == visibleTitles') < search.index('list.swipeUp()')
    assert search.index('swipes >= 40') < search.index('list.swipeUp()')
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
