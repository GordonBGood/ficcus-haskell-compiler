// N-body, 1,000,000 steps: the algorithm of targets/elm/nbody (NBody.elm): five bodies; each step the ten pairs
// (0,1) (0,2) ... (3,4) update both velocities, then every body moves; energies and positions printed as
// JavaScript prints Numbers (js_float below, built on Rust's shortest round-trip digits).
// Choices: Vec<Body> with Body a Copy struct of seven f64 (the Elm Array of records); updates in place by
// index; the arithmetic keeps the Elm operation order exactly (e.g. dx * mass * mag = (dx*mass)*mag), so the
// output equals Elm bit for bit; all indexing checked. No fused multiply-add (rustc does not contract).
// UNCHECKED (`--cfg unchecked`): get_unchecked on the body vector; upper bound only, never the comparison.
#![cfg_attr(not(unchecked), forbid(unsafe_code))]

#[cfg(not(unchecked))]
macro_rules! at { ($v:expr, $i:expr) => { $v[$i] }; }
#[cfg(unchecked)]
macro_rules! at { ($v:expr, $i:expr) => { *unsafe { $v.get_unchecked($i) } }; }
#[cfg(not(unchecked))]
macro_rules! at_mut { ($v:expr, $i:expr) => { $v[$i] }; }
#[cfg(unchecked)]
macro_rules! at_mut { ($v:expr, $i:expr) => { *unsafe { $v.get_unchecked_mut($i) } }; }

const STEPS: usize = 1_000_000;
const DT: f64 = 0.01;
const PI: f64 = 3.141592653589793;
const SOLAR_MASS: f64 = 4.0 * PI * PI;
const DAYS_PER_YEAR: f64 = 365.24;

#[derive(Clone, Copy)]
struct Body { x: f64, y: f64, z: f64, vx: f64, vy: f64, vz: f64, mass: f64 }

const PAIRS: [(usize, usize); 10] = [(0, 1), (0, 2), (0, 3), (0, 4), (1, 2), (1, 3), (1, 4), (2, 3), (2, 4), (3, 4)];

fn initial_bodies() -> Vec<Body> {
    vec![
        Body { x: 0.0, y: 0.0, z: 0.0, vx: 0.0, vy: 0.0, vz: 0.0, mass: SOLAR_MASS },
        Body { x: 4.8414314424647209e0, y: -1.16032004402742839e0, z: -1.03622044471123109e-1,
               vx: 1.66007664274403694e-3 * DAYS_PER_YEAR, vy: 7.69901118419740425e-3 * DAYS_PER_YEAR,
               vz: -6.90460016972063023e-5 * DAYS_PER_YEAR, mass: 9.54791938424326609e-4 * SOLAR_MASS },
        Body { x: 8.34336671824457987e0, y: 4.12479856412430479e0, z: -4.03523417114321381e-1,
               vx: -2.76742510726862411e-3 * DAYS_PER_YEAR, vy: 4.99852801234917238e-3 * DAYS_PER_YEAR,
               vz: 2.30417297573763929e-5 * DAYS_PER_YEAR, mass: 2.85885980666130812e-4 * SOLAR_MASS },
        Body { x: 1.28943695621391310e1, y: -1.51111514016986312e1, z: -2.23307578892655734e-1,
               vx: 2.96460137564761618e-3 * DAYS_PER_YEAR, vy: 2.37847173959480950e-3 * DAYS_PER_YEAR,
               vz: -2.96589568540237556e-5 * DAYS_PER_YEAR, mass: 4.36624404335156298e-5 * SOLAR_MASS },
        Body { x: 1.53796971148509165e1, y: -2.59193146099879641e1, z: 1.79258772950371181e-1,
               vx: 2.68067772490389322e-3 * DAYS_PER_YEAR, vy: 1.62824170038242295e-3 * DAYS_PER_YEAR,
               vz: -9.51592254519715870e-5 * DAYS_PER_YEAR, mass: 5.15138902046611451e-5 * SOLAR_MASS },
    ]
}

fn offset_momentum(bodies: &mut Vec<Body>) {
    let (mut px, mut py, mut pz) = (0.0f64, 0.0f64, 0.0f64);
    for b in bodies.iter() {
        px = px + b.vx * b.mass;
        py = py + b.vy * b.mass;
        pz = pz + b.vz * b.mass;
    }
    let sun = &mut bodies[0];
    sun.vx = -px / SOLAR_MASS;
    sun.vy = -py / SOLAR_MASS;
    sun.vz = -pz / SOLAR_MASS;
}

fn interact(i: usize, j: usize, bodies: &mut Vec<Body>) {
    let bi = at!(bodies, i);
    let bj = at!(bodies, j);
    let dx = bi.x - bj.x;
    let dy = bi.y - bj.y;
    let dz = bi.z - bj.z;
    let d2 = dx * dx + dy * dy + dz * dz;
    let mag = DT / (d2 * d2.sqrt());
    {
        let b = &mut at_mut!(bodies, i);
        b.vx = bi.vx - dx * bj.mass * mag;
        b.vy = bi.vy - dy * bj.mass * mag;
        b.vz = bi.vz - dz * bj.mass * mag;
    }
    {
        let b = &mut at_mut!(bodies, j);
        b.vx = bj.vx + dx * bi.mass * mag;
        b.vy = bj.vy + dy * bi.mass * mag;
        b.vz = bj.vz + dz * bi.mass * mag;
    }
}

fn advance(bodies: &mut Vec<Body>) {
    for &(i, j) in PAIRS.iter() { interact(i, j, bodies); }
    for b in bodies.iter_mut() {
        b.x = b.x + DT * b.vx;
        b.y = b.y + DT * b.vy;
        b.z = b.z + DT * b.vz;
    }
}

fn energy(bodies: &Vec<Body>) -> f64 {
    let mut e = 0.0;
    for i in 0..bodies.len() {
        let b = &bodies[i];
        e = e + 0.5 * b.mass * (b.vx * b.vx + b.vy * b.vy + b.vz * b.vz);
    }
    for &(i, j) in PAIRS.iter() {
        let (bi, bj) = (&bodies[i], &bodies[j]);
        let dx = bi.x - bj.x;
        let dy = bi.y - bj.y;
        let dz = bi.z - bj.z;
        e = e - (bi.mass * bj.mass) / (dx * dx + dy * dy + dz * dz).sqrt();
    }
    e
}

/// String(x) of JavaScript for a finite or non-finite f64
fn js_float(x: f64) -> String {
    if x.is_nan() { return "NaN".to_string(); }
    if x.is_infinite() { return if x > 0.0 { "Infinity" } else { "-Infinity" }.to_string(); }
    if x == 0.0 { return "0".to_string(); }
    let s = format!("{:e}", x.abs()); // shortest digits, "d.ddde-7"
    let (mant, exp) = s.split_once('e').unwrap();
    let digits: String = mant.chars().filter(|c| *c != '.').collect();
    let k = digits.len() as i32;
    let n = exp.parse::<i32>().unwrap() + 1;
    let body = if k <= n && n <= 21 {
        format!("{}{}", digits, "0".repeat((n - k) as usize))
    } else if 0 < n && n <= 21 {
        format!("{}.{}", &digits[..n as usize], &digits[n as usize..])
    } else if -6 < n && n <= 0 {
        format!("0.{}{}", "0".repeat((-n) as usize), digits)
    } else {
        let e = n - 1;
        let sign = if e < 0 { '-' } else { '+' };
        if k == 1 { format!("{}e{}{}", digits, sign, e.abs()) }
        else { format!("{}.{}e{}{}", &digits[..1], &digits[1..], sign, e.abs()) }
    };
    if x < 0.0 { format!("-{}", body) } else { body }
}

fn body_line(name: &str, b: &Body) -> String {
    let v: Vec<String> = [b.x, b.y, b.z, b.vx, b.vy, b.vz].iter().map(|f| js_float(*f)).collect();
    format!("{}: {}", name, v.join(" "))
}

fn main() {
    let mut bodies = initial_bodies();
    offset_momentum(&mut bodies);
    let start = bodies.clone();
    let mut after1000 = Vec::new();
    for s in 0..STEPS {
        advance(&mut bodies);
        if s + 1 == 1000 { after1000 = bodies.clone(); }
    }
    println!("bodies: {}", start.len());
    println!("energy at start: {}", js_float(energy(&start)));
    println!("energy after 1000 steps: {}", js_float(energy(&after1000)));
    println!("energy after {} steps: {}", STEPS, js_float(energy(&bodies)));
    println!("{}", body_line("sun", &bodies[0]));
    println!("{}", body_line("jupiter", &bodies[1]));
    println!("{}", body_line("neptune", &bodies[4]));
}
