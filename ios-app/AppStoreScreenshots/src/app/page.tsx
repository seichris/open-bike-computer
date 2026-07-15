const SLIDES = [
  {
    id: "01-plan-rides",
    src: "/screenshots/appstorepic1.png",
    alt: "Map search screen near Shibuya",
  },
  {
    id: "02-follow-route",
    src: "/screenshots/appstorepic2.png",
    alt: "Active navigation route with turn prompt",
  },
  {
    id: "03-bike-display",
    src: "/screenshots/appstorepic3.png",
    alt: "Bike computer device navigation screens",
  },
] as const;

function Phone({ src, alt, className }: { src: string; alt: string; className: string }) {
  return (
    <div className={`phoneFrame ${className}`}>
      <div className="phoneScreen">
        <img src={src} alt={alt} draggable={false} />
      </div>
      <div className="phoneIsland" />
      <div className="phoneOutline" />
    </div>
  );
}

function SlideOne() {
  return (
    <section className="slide slideOne" data-export-slide={SLIDES[0].id}>
      <div className="slideInner">
        <div className="mapTile" />
        <div className="routeLine" />
        <div className="captionOne">
          <div className="label">Let It Ride</div>
          <h1 className="headline">
            Find your
            <br />
            next ride
          </h1>
          <p className="subhead">Search nearby places and start from the map in seconds.</p>
        </div>
        <Phone src={SLIDES[0].src} alt={SLIDES[0].alt} className="phoneOne" />
      </div>
    </section>
  );
}

function SlideTwo() {
  return (
    <section className="slide slideTwo" data-export-slide={SLIDES[1].id}>
      <div className="slideInner">
        <div className="softGrid" />
        <div className="captionTwo">
          <div className="label">Live Navigation</div>
          <h1 className="headline">
            Ride with
            <br />
            clear cues
          </h1>
          <p className="subhead">Distance, ETA, compass, and route progress stay easy to read.</p>
        </div>
        <Phone src={SLIDES[1].src} alt={SLIDES[1].alt} className="phoneTwo" />
        <div className="statsBand" aria-hidden="true">
          <div className="stat">
            <strong>5</strong>
            <span>min</span>
          </div>
          <div className="stat">
            <strong>1.3</strong>
            <span>km</span>
          </div>
          <div className="stat">
            <strong>12:35</strong>
            <span>arrival</span>
          </div>
        </div>
      </div>
    </section>
  );
}

function SlideThree() {
  return (
    <section className="slide slideThree" data-export-slide={SLIDES[2].id}>
      <div className="slideInner">
        <div className="captionThree">
          <div className="label">Bike Display</div>
          <h1 className="headline">
            Glance down,
            <br />
            keep moving
          </h1>
          <p className="subhead">Send the route to your handlebar screen for simple turn-by-turn guidance.</p>
        </div>
        <img className="deviceArtwork" src={SLIDES[2].src} alt={SLIDES[2].alt} draggable={false} />
      </div>
    </section>
  );
}

export default function ScreenshotsPage() {
  return (
    <main className="page">
      <div className="toolbar">
        <strong>Let It Ride App Store Screenshots</strong>
        <span>Export target: iPhone 6.5&quot; portrait, 1242x2688</span>
      </div>
      <div className="previewGrid" aria-hidden="true">
        {SLIDES.map((slide) => (
          <div className="previewCard" key={slide.id}>
            <img src={slide.src} alt="" draggable={false} />
          </div>
        ))}
      </div>
      <div className="exportStage">
        <SlideOne />
        <SlideTwo />
        <SlideThree />
      </div>
    </main>
  );
}
