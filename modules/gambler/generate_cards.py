#!/usr/bin/env python3
"""
Generate playing card sprites for the Gambler NPC mod using HoH2 art style.
Uses the hoh2-sprite-generator skill utilities.
"""

from PIL import Image, ImageDraw
import sys
import os

sys.path.insert(0, r"C:\Program Files (x86)\Steam\steamapps\common\Heroes of Hammerwatch 2\.claude\skills\hoh2-sprite-generator\scripts")
from hoh2_sprite_gen import ColorPalette, PALETTES

# Card dimensions (must be power-of-two for HoH2 engine)
CARD_WIDTH = 32
CARD_HEIGHT = 64  # Power of two (card content is 48px centered with 8px padding)

# Custom palettes for cards
CARD_BG = ColorPalette.from_base_color(244, 240, 230)  # Cream/off-white
CARD_RED = ColorPalette.from_base_color(180, 50, 50)   # Red for hearts/diamonds
CARD_BLACK = ColorPalette.from_base_color(50, 45, 40)  # Near-black for spades/clubs
CARD_BACK_BLUE = ColorPalette.from_base_color(70, 90, 150)  # Blue for card back
CARD_BACK_GOLD = PALETTES["gold"]  # Gold accents

# Vertical offset for centering 48px content in 64px height
Y_OFFSET = 8

def draw_rounded_rect(draw, x1, y1, x2, y2, palette, corner_radius=2):
    """Draw a rounded rectangle with proper HoH2 shading."""
    # Main fill
    draw.rectangle((x1 + corner_radius, y1, x2 - corner_radius, y2), fill=palette.base)
    draw.rectangle((x1, y1 + corner_radius, x2, y2 - corner_radius), fill=palette.base)

    # Corner fills
    draw.ellipse((x1, y1, x1 + corner_radius*2, y1 + corner_radius*2), fill=palette.base)
    draw.ellipse((x2 - corner_radius*2, y1, x2, y1 + corner_radius*2), fill=palette.base)
    draw.ellipse((x1, y2 - corner_radius*2, x1 + corner_radius*2, y2), fill=palette.base)
    draw.ellipse((x2 - corner_radius*2, y2 - corner_radius*2, x2, y2), fill=palette.base)

    # Top-left highlight edge
    draw.line([(x1 + corner_radius, y1), (x2 - corner_radius, y1)], fill=palette.highlight, width=1)
    draw.line([(x1, y1 + corner_radius), (x1, y2 - corner_radius)], fill=palette.highlight, width=1)

    # Bottom-right shadow edge
    draw.line([(x1 + corner_radius, y2), (x2 - corner_radius, y2)], fill=palette.shadow, width=1)
    draw.line([(x2, y1 + corner_radius), (x2, y2 - corner_radius)], fill=palette.shadow, width=1)

    # Outline
    draw.line([(x1 + corner_radius, y1 - 1), (x2 - corner_radius, y1 - 1)], fill=palette.outline, width=1)
    draw.line([(x1 - 1, y1 + corner_radius), (x1 - 1, y2 - corner_radius)], fill=palette.outline, width=1)
    draw.line([(x1 + corner_radius, y2 + 1), (x2 - corner_radius, y2 + 1)], fill=palette.outline, width=1)
    draw.line([(x2 + 1, y1 + corner_radius), (x2 + 1, y2 - corner_radius)], fill=palette.outline, width=1)

def create_card_base():
    """Create the base card image with cream background."""
    img = Image.new('RGBA', (CARD_WIDTH, CARD_HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Draw card background with rounded corners (48px height centered in 64px)
    draw_rounded_rect(draw, 2, 2 + Y_OFFSET, CARD_WIDTH - 3, CARD_HEIGHT - 3 - Y_OFFSET, CARD_BG, corner_radius=2)

    return img

def draw_heart(draw, cx, cy, size, palette):
    """Draw a heart symbol with smooth pixel art."""
    if size <= 4:
        # Tiny heart (3x3)
        draw.point((cx - 1, cy - 1), fill=palette.base)
        draw.point((cx + 1, cy - 1), fill=palette.base)
        draw.point((cx - 1, cy), fill=palette.base)
        draw.point((cx, cy), fill=palette.base)
        draw.point((cx + 1, cy), fill=palette.base)
        draw.point((cx, cy + 1), fill=palette.base)
        draw.point((cx, cy - 1), fill=palette.highlight)
    else:
        # Larger heart - pixel by pixel for smooth curves
        # Row by row from top to bottom (relative to center)
        heart_pixels = [
            # Top row - two bumps with gap
            (-3, -3), (-2, -3), (2, -3), (3, -3),
            # Second row - bumps widen
            (-4, -2), (-3, -2), (-2, -2), (-1, -2), (1, -2), (2, -2), (3, -2), (4, -2),
            # Third row - bumps merge
            (-4, -1), (-3, -1), (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1), (3, -1), (4, -1),
            # Middle rows - full width tapering down
            (-4, 0), (-3, 0), (-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
            (-3, 1), (-2, 1), (-1, 1), (0, 1), (1, 1), (2, 1), (3, 1),
            (-2, 2), (-1, 2), (0, 2), (1, 2), (2, 2),
            (-1, 3), (0, 3), (1, 3),
            (0, 4),
        ]
        for dx, dy in heart_pixels:
            draw.point((cx + dx, cy + dy), fill=palette.base)
        # Highlight on upper left bump
        for dx, dy in [(-3, -2), (-2, -2), (-3, -1)]:
            draw.point((cx + dx, cy + dy), fill=palette.highlight)

def draw_diamond(draw, cx, cy, size, palette):
    """Draw a diamond symbol."""
    s = size / 5
    if size <= 4:
        draw.point((cx, cy - 1), fill=palette.base)
        draw.point((cx - 1, cy), fill=palette.base)
        draw.point((cx + 1, cy), fill=palette.base)
        draw.point((cx, cy + 1), fill=palette.base)
        draw.point((cx, cy), fill=palette.highlight)
    else:
        points = [
            (cx, cy - int(4*s)),
            (cx + int(3*s), cy),
            (cx, cy + int(4*s)),
            (cx - int(3*s), cy),
        ]
        draw.polygon(points, fill=palette.base, outline=palette.outline)
        # Highlight on left facet
        highlight = [
            (cx, cy - int(3*s)),
            (cx - int(2*s), cy),
            (cx, cy),
        ]
        draw.polygon(highlight, fill=palette.highlight)

def draw_spade(draw, cx, cy, size, palette):
    """Draw a spade symbol with smooth pixel art."""
    if size <= 4:
        # Tiny spade
        draw.point((cx, cy - 1), fill=palette.base)
        draw.point((cx - 1, cy), fill=palette.base)
        draw.point((cx, cy), fill=palette.base)
        draw.point((cx + 1, cy), fill=palette.base)
        draw.point((cx, cy + 1), fill=palette.shadow)
    else:
        # Larger spade - pixel by pixel
        spade_pixels = [
            # Top point
            (0, -4),
            (-1, -3), (0, -3), (1, -3),
            (-2, -2), (-1, -2), (0, -2), (1, -2), (2, -2),
            (-3, -1), (-2, -1), (-1, -1), (0, -1), (1, -1), (2, -1), (3, -1),
            # Widest part
            (-4, 0), (-3, 0), (-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
            # Bottom lobes curving inward toward stem
            (-4, 1), (-3, 1), (-2, 1), (2, 1), (3, 1), (4, 1),
            (-3, 2), (3, 2),
        ]
        for dx, dy in spade_pixels:
            draw.point((cx + dx, cy + dy), fill=palette.base)
        # Stem with smooth transition from lobes
        stem_pixels = [
            # Transition row - lobes curve into stem
            (-2, 2), (-1, 2), (0, 2), (1, 2), (2, 2),
            # Stem narrows
            (-1, 3), (0, 3), (1, 3),
            # Base widens
            (-2, 4), (-1, 4), (0, 4), (1, 4), (2, 4),
        ]
        for dx, dy in stem_pixels:
            draw.point((cx + dx, cy + dy), fill=palette.shadow)
        # Fill center of stem transition with base color for depth
        for dx, dy in [(-1, 1), (0, 1), (1, 1)]:
            draw.point((cx + dx, cy + dy), fill=palette.shadow)
        # Highlight on upper left
        for dx, dy in [(-1, -3), (-2, -2), (-3, -1)]:
            draw.point((cx + dx, cy + dy), fill=palette.highlight)

def draw_club(draw, cx, cy, size, palette):
    """Draw a club symbol with smooth pixel art."""
    if size <= 4:
        # Tiny club
        draw.point((cx, cy - 1), fill=palette.base)
        draw.point((cx - 1, cy), fill=palette.base)
        draw.point((cx, cy), fill=palette.base)
        draw.point((cx + 1, cy), fill=palette.base)
        draw.point((cx, cy + 1), fill=palette.shadow)
    else:
        # Larger club - three overlapping circles with stem
        club_pixels = [
            # Top lobe
            (-1, -4), (0, -4), (1, -4),
            (-2, -3), (-1, -3), (0, -3), (1, -3), (2, -3),
            (-2, -2), (-1, -2), (0, -2), (1, -2), (2, -2),
            # Left lobe
            (-4, -1), (-3, -1), (-2, -1),
            (-4, 0), (-3, 0), (-2, 0),
            (-4, 1), (-3, 1), (-2, 1),
            (-3, 2), (-2, 2),
            # Right lobe
            (2, -1), (3, -1), (4, -1),
            (2, 0), (3, 0), (4, 0),
            (2, 1), (3, 1), (4, 1),
            (2, 2), (3, 2),
            # Center connection
            (-1, -1), (0, -1), (1, -1),
            (-1, 0), (0, 0), (1, 0),
            (-1, 1), (0, 1), (1, 1),
        ]
        for dx, dy in club_pixels:
            draw.point((cx + dx, cy + dy), fill=palette.base)
        # Stem (darker)
        stem_pixels = [
            (-1, 2), (0, 2), (1, 2),
            (-1, 3), (0, 3), (1, 3),
            (-2, 4), (-1, 4), (0, 4), (1, 4), (2, 4),
        ]
        for dx, dy in stem_pixels:
            draw.point((cx + dx, cy + dy), fill=palette.shadow)
        # Highlight on top lobe
        for dx, dy in [(-1, -4), (0, -4), (-2, -3), (-1, -3)]:
            draw.point((cx + dx, cy + dy), fill=palette.highlight)

SUIT_DRAWERS = {
    'h': draw_heart,
    'd': draw_diamond,
    's': draw_spade,
    'c': draw_club,
}

# Pixel art digits (3x5 grid, stored as list of (x,y) offsets)
DIGITS = {
    'A': [(1,0), (0,1), (2,1), (0,2), (1,2), (2,2), (0,3), (2,3), (0,4), (2,4)],
    '2': [(0,0), (1,0), (2,0), (2,1), (0,2), (1,2), (2,2), (0,3), (0,4), (1,4), (2,4)],
    '3': [(0,0), (1,0), (2,0), (2,1), (1,2), (2,2), (2,3), (0,4), (1,4), (2,4)],
    '4': [(0,0), (2,0), (0,1), (2,1), (0,2), (1,2), (2,2), (2,3), (2,4)],
    '5': [(0,0), (1,0), (2,0), (0,1), (0,2), (1,2), (2,2), (2,3), (0,4), (1,4), (2,4)],
    '6': [(0,0), (1,0), (2,0), (0,1), (0,2), (1,2), (2,2), (0,3), (2,3), (0,4), (1,4), (2,4)],
    '7': [(0,0), (1,0), (2,0), (2,1), (2,2), (2,3), (2,4)],
    '8': [(0,0), (1,0), (2,0), (0,1), (2,1), (0,2), (1,2), (2,2), (0,3), (2,3), (0,4), (1,4), (2,4)],
    '9': [(0,0), (1,0), (2,0), (0,1), (2,1), (0,2), (1,2), (2,2), (2,3), (0,4), (1,4), (2,4)],
    '0': [(0,0), (1,0), (2,0), (0,1), (2,1), (0,2), (2,2), (0,3), (2,3), (0,4), (1,4), (2,4)],
    '1': [(1,0), (0,1), (1,1), (1,2), (1,3), (0,4), (1,4), (2,4)],
    'J': [(2,0), (2,1), (2,2), (0,3), (2,3), (0,4), (1,4), (2,4)],
    'Q': [(0,0), (1,0), (2,0), (0,1), (2,1), (0,2), (2,2), (0,3), (1,3), (1,4), (2,4)],
    'K': [(0,0), (2,0), (0,1), (1,1), (0,2), (1,2), (0,3), (1,3), (0,4), (2,4)],
}

def draw_value(draw, x, y, value, color):
    """Draw a card value at the given position."""
    if value == 10:
        # Draw "10" - "1" at x, "0" at x+4
        for px, py in DIGITS['1']:
            draw.point((x + px, y + py), fill=color)
        for px, py in DIGITS['0']:
            draw.point((x + px + 4, y + py), fill=color)
    else:
        char = {1: 'A', 11: 'J', 12: 'Q', 13: 'K'}.get(value, str(value))
        for px, py in DIGITS.get(char, []):
            draw.point((x + px, y + py), fill=color)

def create_card_face(value, suit):
    """Create a card face with value and suit."""
    img = create_card_base()
    draw = ImageDraw.Draw(img)

    palette = CARD_RED if suit in ['h', 'd'] else CARD_BLACK
    text_color = palette.base

    # Card content height (48px centered in 64px)
    content_top = Y_OFFSET
    content_bottom = CARD_HEIGHT - Y_OFFSET
    content_center_y = CARD_HEIGHT // 2

    # Top-left value
    draw_value(draw, 4, 5 + content_top, value, text_color)

    # Top-left suit symbol (small)
    SUIT_DRAWERS[suit](draw, 6, 14 + content_top, 4, palette)

    # Center suit symbol (large)
    SUIT_DRAWERS[suit](draw, CARD_WIDTH // 2, content_center_y, 10, palette)

    # Bottom-right value (positioned for 10 to fit)
    if value == 10:
        draw_value(draw, CARD_WIDTH - 11, content_bottom - 10, value, text_color)
    else:
        draw_value(draw, CARD_WIDTH - 7, content_bottom - 10, value, text_color)

    # Bottom-right suit symbol (small)
    SUIT_DRAWERS[suit](draw, CARD_WIDTH - 6, content_bottom - 15, 4, palette)

    return img

def create_card_back():
    """Create the card back with decorative pattern."""
    img = Image.new('RGBA', (CARD_WIDTH, CARD_HEIGHT), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Card content area (48px centered in 64px)
    content_top = Y_OFFSET
    content_bottom = CARD_HEIGHT - Y_OFFSET

    # Draw blue card background
    draw_rounded_rect(draw, 2, 2 + content_top, CARD_WIDTH - 3, content_bottom - 2, CARD_BACK_BLUE, corner_radius=2)

    # Inner border with gold
    draw.rectangle((5, 5 + content_top, CARD_WIDTH - 6, content_bottom - 6), outline=CARD_BACK_GOLD.base)
    draw.rectangle((6, 6 + content_top, CARD_WIDTH - 7, content_bottom - 7), outline=CARD_BACK_GOLD.shadow)

    # Diamond pattern in center
    cx, cy = CARD_WIDTH // 2, CARD_HEIGHT // 2

    # Central diamond
    diamond_points = [
        (cx, cy - 8),
        (cx + 6, cy),
        (cx, cy + 8),
        (cx - 6, cy),
    ]
    draw.polygon(diamond_points, fill=CARD_BACK_GOLD.base, outline=CARD_BACK_GOLD.outline)

    # Highlight on diamond
    highlight_points = [
        (cx, cy - 6),
        (cx - 4, cy),
        (cx, cy),
    ]
    draw.polygon(highlight_points, fill=CARD_BACK_GOLD.highlight)

    # Small corner diamonds
    for corner_x, corner_y in [(10, 12 + content_top), (CARD_WIDTH - 10, 12 + content_top),
                                (10, content_bottom - 12), (CARD_WIDTH - 10, content_bottom - 12)]:
        small_diamond = [
            (corner_x, corner_y - 3),
            (corner_x + 2, corner_y),
            (corner_x, corner_y + 3),
            (corner_x - 2, corner_y),
        ]
        draw.polygon(small_diamond, fill=CARD_BACK_GOLD.base, outline=CARD_BACK_GOLD.outline)

    return img

def main():
    output_dir = os.path.join(os.path.dirname(__file__), 'gui', 'cards')
    os.makedirs(output_dir, exist_ok=True)

    # Generate card back
    card_back = create_card_back()
    card_back.save(os.path.join(output_dir, 'card_back.png'), 'PNG', optimize=True)
    print("Generated card_back.png")

    # Generate all 52 card faces
    suits = ['h', 'd', 's', 'c']
    for suit in suits:
        for value in range(1, 14):
            card = create_card_face(value, suit)
            filename = f"card_{suit}_{value:02d}.png"
            card.save(os.path.join(output_dir, filename), 'PNG', optimize=True)
            print(f"Generated {filename}")

    print(f"\nGenerated 53 card sprites in {output_dir}")

if __name__ == '__main__':
    main()
