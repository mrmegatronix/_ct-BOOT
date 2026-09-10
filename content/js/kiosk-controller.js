/**
 * Kiosk Presentation & Hardware Keyboard Controller
 * Strict adherence to protocol navigation and UI rules
 */

class KioskController {
    constructor() {
        this.slides = Array.from(document.querySelectorAll('.slide'));
        this.currentSlideIndex = 0;
        this.currentModuleIndex = 0;
        this.modules = this.groupSlidesByModule();

        this.slideDurationSec = 10; // Default 10s
        this.isPaused = false;
        this.isLocked = false;
        this.timer = null;
        this.progressInterval = null;
        this.elapsedMs = 0;

        this.statusBadge = document.getElementById('status-badge');
        this.clockContainer = document.getElementById('kiosk-clock');
        this.progressFill = document.getElementById('progress-fill');

        this.init();
    }

    init() {
        this.initClock();
        this.bindKeyboardShortcuts();
        this.showSlide(0);
        this.startTimer();
    }

    groupSlidesByModule() {
        const modulesMap = new Map();
        this.slides.forEach((slide, idx) => {
            const mod = slide.dataset.module || 'default';
            if (!modulesMap.has(mod)) {
                modulesMap.set(mod, []);
            }
            modulesMap.get(mod).push(idx);
        });
        return Array.from(modulesMap.values());
    }

    /* Clock with blinking colon */
    initClock() {
        const updateClock = () => {
            if (!this.clockContainer) return;
            const now = new Date();
            const h = String(now.getHours()).padStart(2, '0');
            const m = String(now.getMinutes()).padStart(2, '0');
            const s = String(now.getSeconds()).padStart(2, '0');
            this.clockContainer.innerHTML = `${h}<span class="colon-blink">:</span>${m}<span class="colon-blink">:</span>${s}`;
        };
        updateClock();
        setInterval(updateClock, 1000);
    }

    /* Keyboard shortcuts */
    bindKeyboardShortcuts() {
        window.addEventListener('keydown', (e) => {
            // Input guard
            const tag = document.activeElement ? document.activeElement.tagName.toLowerCase() : '';
            if (tag === 'input' || tag === 'textarea' || tag === 'select') {
                return;
            }

            switch (e.key) {
                case 'ArrowLeft':
                    e.preventDefault();
                    this.prevSlide();
                    break;
                case 'ArrowRight':
                    e.preventDefault();
                    this.nextSlide();
                    break;
                case 'ArrowUp':
                    e.preventDefault();
                    this.restartModule();
                    break;
                case 'ArrowDown':
                    e.preventDefault();
                    this.nextModule();
                    break;
                case ' ':
                case 'Spacebar':
                    e.preventDefault();
                    this.togglePause();
                    break;
                case 'a':
                case 'A':
                    e.preventDefault();
                    window.open('admin.html', '_blank');
                    break;
                case 'r':
                case 'R':
                    e.preventDefault();
                    window.open('remote.html', '_blank');
                    break;
                case '0':
                    e.preventDefault();
                    this.toggleLock();
                    break;
                default:
                    // Numeric keys 1-9
                    if (/^[1-9]$/.test(e.key)) {
                        e.preventDefault();
                        const digit = parseInt(e.key, 10);
                        this.setDuration(digit * 10);
                    }
                    break;
            }
        });
    }

    showSlide(index) {
        if (this.slides.length === 0) return;
        this.currentSlideIndex = (index + this.slides.length) % this.slides.length;
        this.slides.forEach((s, idx) => {
            s.classList.toggle('active', idx === this.currentSlideIndex);
        });

        // Determine current module
        for (let m = 0; m < this.modules.length; m++) {
            if (this.modules[m].includes(this.currentSlideIndex)) {
                this.currentModuleIndex = m;
                break;
            }
        }

        this.restartActiveTimer();
    }

    prevSlide() {
        this.showSlide(this.currentSlideIndex - 1);
    }

    nextSlide() {
        this.showSlide(this.currentSlideIndex + 1);
    }

    restartModule() {
        const currentModSlides = this.modules[this.currentModuleIndex];
        if (currentModSlides && currentModSlides.length > 0) {
            this.showSlide(currentModSlides[0]);
        } else {
            this.showSlide(0);
        }
    }

    nextModule() {
        const nextModIdx = (this.currentModuleIndex + 1) % this.modules.length;
        const nextModSlides = this.modules[nextModIdx];
        if (nextModSlides && nextModSlides.length > 0) {
            this.showSlide(nextModSlides[0]);
        }
    }

    togglePause() {
        this.isPaused = !this.isPaused;
        this.updateStatusBadge();
    }

    toggleLock() {
        this.isLocked = !this.isLocked;
        this.updateStatusBadge();
    }

    setDuration(seconds) {
        this.slideDurationSec = seconds;
        this.updateStatusBadge();
        this.restartActiveTimer();
    }

    updateStatusBadge() {
        if (!this.statusBadge) return;
        if (this.isLocked) {
            this.statusBadge.textContent = 'LOCKED';
            this.statusBadge.className = 'status-badge locked';
        } else if (this.isPaused) {
            this.statusBadge.textContent = 'PAUSED';
            this.statusBadge.className = 'status-badge paused';
        } else {
            this.statusBadge.textContent = `LIVE (${this.slideDurationSec}s)`;
            this.statusBadge.className = 'status-badge live';
        }
    }

    startTimer() {
        this.stopTimer();
        this.elapsedMs = 0;
        this.updateStatusBadge();

        const tickInterval = 50;
        this.progressInterval = setInterval(() => {
            if (this.isPaused || this.isLocked) {
                return;
            }

            this.elapsedMs += tickInterval;
            const totalMs = this.slideDurationSec * 1000;
            const percentage = Math.min(100, (this.elapsedMs / totalMs) * 100);

            if (this.progressFill) {
                this.progressFill.style.width = `${percentage}%`;
            }

            if (this.elapsedMs >= totalMs) {
                this.nextSlide();
            }
        }, tickInterval);
    }

    stopTimer() {
        if (this.progressInterval) {
            clearInterval(this.progressInterval);
            this.progressInterval = null;
        }
    }

    restartActiveTimer() {
        this.elapsedMs = 0;
        if (this.progressFill) {
            this.progressFill.style.width = '0%';
        }
        if (!this.progressInterval) {
            this.startTimer();
        }
    }
}

document.addEventListener('DOMContentLoaded', () => {
    window.kiosk = new KioskController();
});
